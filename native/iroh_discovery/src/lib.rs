use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::num::NonZeroU16;
use std::path::{Path, PathBuf};

use iroh::{EndpointId, SecretKey, Signature};
use thiserror::Error;

pub mod dist;
pub mod transport;

const DOMAIN: &[u8] = b"elixir-rpc/cdp/v1\0";
const MAX_MESSAGE_SIZE: usize = 16 * 1024;
const MAX_AUTHORIZED: usize = 1_024;
const RATE_LIMIT: usize = 10;
const RATE_WINDOW_MS: u64 = 1_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum Error {
    #[error("malformed")]
    Malformed,
    #[error("unsupported_version")]
    UnsupportedVersion,
    #[error("message_too_large")]
    MessageTooLarge,
    #[error("wrong_fleet")]
    WrongFleet,
    #[error("unauthorized_endpoint")]
    UnauthorizedEndpoint,
    #[error("invalid_signature")]
    InvalidSignature,
    #[error("invalid_record")]
    InvalidRecord,
    #[error("stale_sequence")]
    StaleSequence,
    #[error("no_matching_peer")]
    NoMatchingPeer,
    #[error("peer_unavailable")]
    PeerUnavailable,
    #[error("rate_limited")]
    RateLimited,
    #[error("sequence_store_failed")]
    SequenceStoreFailed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CapabilityValue {
    Bool(bool),
    Uint(u64),
    Text(String),
    TextList(Vec<String>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Load {
    pub running: u64,
    pub capacity: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Announcement {
    pub fleet_id: [u8; 32],
    pub endpoint_id: EndpointId,
    pub node_name: String,
    pub partisan_ip: [u8; 4],
    pub partisan_port: NonZeroU16,
    pub sequence: u64,
    pub ttl_ms: u64,
    pub capabilities: BTreeMap<String, CapabilityValue>,
    pub load: Load,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Withdrawal {
    pub fleet_id: [u8; 32],
    pub endpoint_id: EndpointId,
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Predicate {
    Equals(String, CapabilityValue),
    AtLeast(String, u64),
    Contains(String, String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Peer {
    pub endpoint_id: EndpointId,
    pub node_name: String,
    pub partisan_ip: [u8; 4],
    pub partisan_port: NonZeroU16,
    pub sequence: u64,
    pub capabilities: BTreeMap<String, CapabilityValue>,
}

/// Implementations must make `advance` durable before returning success.
pub trait SequenceStore {
    fn load(&self, endpoint: &EndpointId) -> Result<u64, Error>;
    fn advance(&mut self, endpoint: EndpointId, sequence: u64) -> Result<(), Error>;
}

#[derive(Debug, Default)]
pub struct MemorySequenceStore(HashMap<EndpointId, u64>);

impl SequenceStore for MemorySequenceStore {
    fn load(&self, endpoint: &EndpointId) -> Result<u64, Error> {
        Ok(self.0.get(endpoint).copied().unwrap_or(0))
    }

    fn advance(&mut self, endpoint: EndpointId, sequence: u64) -> Result<(), Error> {
        if sequence <= self.load(&endpoint)? {
            return Err(Error::StaleSequence);
        }
        self.0.insert(endpoint, sequence);
        Ok(())
    }
}

#[derive(Debug)]
pub struct FileSequenceStore {
    path: PathBuf,
    sequences: BTreeMap<EndpointId, u64>,
}

impl FileSequenceStore {
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, Error> {
        let path = path.into();
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(_) => return Err(Error::SequenceStoreFailed),
        };
        if bytes.len() % 40 != 0 || bytes.len() / 40 > MAX_AUTHORIZED {
            return Err(Error::SequenceStoreFailed);
        }
        let mut sequences = BTreeMap::new();
        for record in bytes.chunks_exact(40) {
            let endpoint = EndpointId::from_bytes(
                record[..32]
                    .try_into()
                    .map_err(|_| Error::SequenceStoreFailed)?,
            )
            .map_err(|_| Error::SequenceStoreFailed)?;
            let sequence = u64::from_be_bytes(
                record[32..]
                    .try_into()
                    .map_err(|_| Error::SequenceStoreFailed)?,
            );
            if sequence == 0 || sequences.insert(endpoint, sequence).is_some() {
                return Err(Error::SequenceStoreFailed);
            }
        }
        Ok(Self { path, sequences })
    }

    fn persist(&self) -> Result<(), Error> {
        let mut bytes = Vec::with_capacity(self.sequences.len() * 40);
        for (endpoint, sequence) in &self.sequences {
            bytes.extend_from_slice(endpoint.as_bytes());
            bytes.extend_from_slice(&sequence.to_be_bytes());
        }
        atomic_write(&self.path, &bytes).map_err(|_| Error::SequenceStoreFailed)
    }
}

impl SequenceStore for FileSequenceStore {
    fn load(&self, endpoint: &EndpointId) -> Result<u64, Error> {
        Ok(self.sequences.get(endpoint).copied().unwrap_or(0))
    }

    fn advance(&mut self, endpoint: EndpointId, sequence: u64) -> Result<(), Error> {
        if sequence <= self.load(&endpoint)? {
            return Err(Error::StaleSequence);
        }
        if !self.sequences.contains_key(&endpoint) && self.sequences.len() == MAX_AUTHORIZED {
            return Err(Error::SequenceStoreFailed);
        }
        let previous = self.sequences.insert(endpoint, sequence);
        if let Err(error) = self.persist() {
            match previous {
                Some(value) => self.sequences.insert(endpoint, value),
                None => self.sequences.remove(&endpoint),
            };
            return Err(error);
        }
        Ok(())
    }
}

pub fn load_or_create_secret(path: &Path) -> io::Result<SecretKey> {
    match fs::read(path) {
        Ok(bytes) => {
            let bytes: [u8; 32] = bytes
                .try_into()
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid secret key"))?;
            Ok(SecretKey::from_bytes(&bytes))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let secret = SecretKey::generate();
            atomic_write(path, &secret.to_bytes())?;
            Ok(secret)
        }
        Err(error) => Err(error),
    }
}

fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(format!(".tmp-{}", std::process::id()));
    let temporary = PathBuf::from(temporary);
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

/// Durably reserves the next sender sequence before it may be signed.
pub fn reserve_next(store: &mut impl SequenceStore, endpoint: EndpointId) -> Result<u64, Error> {
    let next = store
        .load(&endpoint)?
        .checked_add(1)
        .ok_or(Error::InvalidRecord)?;
    store.advance(endpoint, next)?;
    Ok(next)
}

#[derive(Debug, Clone)]
pub struct AuthorizationTable(BTreeMap<EndpointId, String>);

impl AuthorizationTable {
    pub fn new(entries: impl IntoIterator<Item = (EndpointId, String)>) -> Result<Self, Error> {
        let entries: BTreeMap<_, _> = entries.into_iter().collect();
        if entries.len() > MAX_AUTHORIZED
            || entries
                .values()
                .any(|node_name| !valid_node_name(node_name))
        {
            return Err(Error::InvalidRecord);
        }
        Ok(Self(entries))
    }

    pub fn authorize(&mut self, endpoint: EndpointId, node_name: String) -> Result<(), Error> {
        if !valid_node_name(&node_name)
            || (!self.0.contains_key(&endpoint) && self.0.len() == MAX_AUTHORIZED)
        {
            return Err(Error::InvalidRecord);
        }
        self.0.insert(endpoint, node_name);
        Ok(())
    }

    pub fn revoke(&mut self, endpoint: &EndpointId) {
        self.0.remove(endpoint);
    }

    fn node_name(&self, endpoint: &EndpointId) -> Option<&str> {
        self.0.get(endpoint).map(String::as_str)
    }
}

#[derive(Debug, Clone)]
struct ActiveRecord {
    announcement: Announcement,
    received_at: u64,
}

pub struct Registry<S> {
    fleet_id: [u8; 32],
    authorization: AuthorizationTable,
    enrollment: EnrollmentPolicy,
    store: S,
    records: HashMap<EndpointId, ActiveRecord>,
    rate: HashMap<EndpointId, VecDeque<u64>>,
}

/// Controls whether a valid signed announcement may enroll its own endpoint identity.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum EnrollmentPolicy {
    /// Only endpoints already present in the authorization table are accepted.
    #[default]
    Strict,
    /// Enroll an unknown endpoint and its signed node name after canonical decoding,
    /// exact fleet matching, and signature verification. The authorization-table bound applies.
    SignedFleet,
}

impl<S: SequenceStore> Registry<S> {
    pub fn new(fleet_id: [u8; 32], authorization: AuthorizationTable, store: S) -> Self {
        Self {
            fleet_id,
            authorization,
            enrollment: EnrollmentPolicy::Strict,
            store,
            records: HashMap::new(),
            rate: HashMap::new(),
        }
    }

    pub fn with_enrollment_policy(mut self, enrollment: EnrollmentPolicy) -> Self {
        self.enrollment = enrollment;
        self
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    pub fn revoke(&mut self, endpoint: &EndpointId) {
        self.authorization.revoke(endpoint);
        self.records.remove(endpoint);
        self.rate.remove(endpoint);
    }

    pub fn authorize(&mut self, endpoint: EndpointId, node_name: String) -> Result<(), Error> {
        self.authorization.authorize(endpoint, node_name)
    }

    pub fn receive(&mut self, envelope: &[u8], now: u64) -> Result<(), Error> {
        if envelope.len() > MAX_MESSAGE_SIZE {
            return Err(Error::MessageTooLarge);
        }
        let (body, signature) = decode_envelope(envelope)?;
        let message = decode_message(&body)?;
        let endpoint = message.endpoint_id();
        if message.fleet_id() != self.fleet_id {
            return Err(Error::WrongFleet);
        }
        let enrolled_name = self.authorization.node_name(&endpoint).map(str::to_owned);
        if enrolled_name.is_none() && self.enrollment == EnrollmentPolicy::Strict {
            return Err(Error::UnauthorizedEndpoint);
        }
        if enrolled_name.is_some() {
            self.check_rate(endpoint, now)?;
        }
        let mut signed = Vec::with_capacity(DOMAIN.len() + body.len());
        signed.extend_from_slice(DOMAIN);
        signed.extend_from_slice(&body);
        endpoint
            .verify(&signed, &signature)
            .map_err(|_| Error::InvalidSignature)?;

        let enrolled_name = match (enrolled_name, &message, self.enrollment) {
            (Some(name), _, _) => name,
            (None, Message::Announcement(announcement), EnrollmentPolicy::SignedFleet) => {
                validate_announcement(announcement)?;
                self.authorization
                    .authorize(endpoint, announcement.node_name.clone())?;
                self.check_rate(endpoint, now)?;
                announcement.node_name.clone()
            }
            _ => return Err(Error::UnauthorizedEndpoint),
        };

        match message {
            Message::Announcement(announcement) => {
                validate_announcement(&announcement)?;
                if announcement.node_name != enrolled_name {
                    return Err(Error::UnauthorizedEndpoint);
                }
                self.accept_sequence(endpoint, announcement.sequence)?;
                self.records.insert(
                    endpoint,
                    ActiveRecord {
                        announcement,
                        received_at: now,
                    },
                );
            }
            Message::Withdrawal(withdrawal) => {
                validate_withdrawal(&withdrawal)?;
                self.accept_sequence(endpoint, withdrawal.sequence)?;
                self.records.remove(&endpoint);
            }
        }
        Ok(())
    }

    pub fn active(&mut self, endpoint: &EndpointId, now: u64) -> Option<&Announcement> {
        self.expire(now);
        self.records.get(endpoint).map(|r| &r.announcement)
    }

    pub fn find(&mut self, predicates: &[Predicate], now: u64) -> Result<Vec<Peer>, Error> {
        self.expire(now);
        let mut matches: Vec<_> = self
            .records
            .values()
            .filter(|record| {
                let announcement = &record.announcement;
                announcement.load.running < announcement.load.capacity
                    && predicates
                        .iter()
                        .all(|predicate| matches_predicate(announcement, predicate))
            })
            .collect();
        matches.sort_by(|a, b| compare_records(&a.announcement, &b.announcement));
        let peers = matches
            .into_iter()
            .map(|record| Peer {
                endpoint_id: record.announcement.endpoint_id,
                node_name: record.announcement.node_name.clone(),
                partisan_ip: record.announcement.partisan_ip,
                partisan_port: record.announcement.partisan_port,
                sequence: record.announcement.sequence,
                capabilities: record.announcement.capabilities.clone(),
            })
            .collect::<Vec<_>>();
        if peers.is_empty() {
            Err(Error::NoMatchingPeer)
        } else {
            Ok(peers)
        }
    }

    /// Resolves an active, signature-verified node binding.
    pub fn endpoint_for_node(&mut self, node_name: &str, now: u64) -> Option<EndpointId> {
        self.expire(now);
        self.records
            .values()
            .find(|record| record.announcement.node_name == node_name)
            .map(|record| record.announcement.endpoint_id)
    }

    /// Returns active verified bindings and their remaining lifetime in milliseconds.
    pub fn bindings(&mut self, now: u64) -> Vec<(EndpointId, String, u64)> {
        self.expire(now);
        self.records
            .values()
            .map(|record| {
                let announcement = &record.announcement;
                (
                    announcement.endpoint_id,
                    announcement.node_name.clone(),
                    record
                        .received_at
                        .saturating_add(announcement.ttl_ms)
                        .saturating_sub(now),
                )
            })
            .collect()
    }

    fn accept_sequence(&mut self, endpoint: EndpointId, sequence: u64) -> Result<(), Error> {
        if sequence <= self.store.load(&endpoint)? {
            return Err(Error::StaleSequence);
        }
        self.store.advance(endpoint, sequence)
    }

    fn check_rate(&mut self, endpoint: EndpointId, now: u64) -> Result<(), Error> {
        let times = self.rate.entry(endpoint).or_default();
        while times
            .front()
            .is_some_and(|time| time.saturating_add(RATE_WINDOW_MS) <= now)
        {
            times.pop_front();
        }
        if times.len() == RATE_LIMIT {
            return Err(Error::RateLimited);
        }
        times.push_back(now);
        Ok(())
    }

    fn expire(&mut self, now: u64) {
        self.records.retain(|_, record| {
            record
                .received_at
                .saturating_add(record.announcement.ttl_ms)
                > now
        });
    }
}

fn matches_predicate(announcement: &Announcement, predicate: &Predicate) -> bool {
    match predicate {
        Predicate::Equals(name, expected) => announcement.capabilities.get(name) == Some(expected),
        Predicate::AtLeast(name, minimum) => matches!(
            announcement.capabilities.get(name),
            Some(CapabilityValue::Uint(value)) if value >= minimum
        ),
        Predicate::Contains(name, needle) => matches!(
            announcement.capabilities.get(name),
            Some(CapabilityValue::TextList(values)) if values.contains(needle)
        ),
    }
}

fn compare_records(a: &Announcement, b: &Announcement) -> Ordering {
    (a.load.running as u128 * b.load.capacity as u128)
        .cmp(&(b.load.running as u128 * a.load.capacity as u128))
        .then_with(|| (b.load.capacity - b.load.running).cmp(&(a.load.capacity - a.load.running)))
        .then_with(|| a.endpoint_id.cmp(&b.endpoint_id))
}

pub fn sign_announcement(
    announcement: &Announcement,
    secret: &SecretKey,
) -> Result<Vec<u8>, Error> {
    validate_announcement(announcement)?;
    if announcement.endpoint_id != secret.public() {
        return Err(Error::InvalidSignature);
    }
    sign_body(encode_announcement(announcement), secret)
}

pub fn sign_withdrawal(withdrawal: &Withdrawal, secret: &SecretKey) -> Result<Vec<u8>, Error> {
    validate_withdrawal(withdrawal)?;
    if withdrawal.endpoint_id != secret.public() {
        return Err(Error::InvalidSignature);
    }
    sign_body(encode_withdrawal(withdrawal), secret)
}

fn sign_body(body: Vec<u8>, secret: &SecretKey) -> Result<Vec<u8>, Error> {
    let mut signed = Vec::with_capacity(DOMAIN.len() + body.len());
    signed.extend_from_slice(DOMAIN);
    signed.extend_from_slice(&body);
    let envelope = encode_envelope(&body, &secret.sign(&signed).to_bytes());
    if envelope.len() > MAX_MESSAGE_SIZE {
        Err(Error::MessageTooLarge)
    } else {
        Ok(envelope)
    }
}

fn validate_announcement(value: &Announcement) -> Result<(), Error> {
    if value.sequence == 0
        || !(5_000..=60_000).contains(&value.ttl_ms)
        || !valid_node_name(&value.node_name)
        || value.capabilities.len() > 32
        || value.load.capacity == 0
        || value.load.capacity > 65_535
        || value.load.running > value.load.capacity
        || value
            .capabilities
            .iter()
            .any(|(name, capability)| !valid_capability(name, capability))
    {
        return Err(Error::InvalidRecord);
    }
    Ok(())
}

fn validate_withdrawal(value: &Withdrawal) -> Result<(), Error> {
    if value.sequence == 0 {
        Err(Error::InvalidRecord)
    } else {
        Ok(())
    }
}

pub(crate) fn valid_node_name(value: &str) -> bool {
    let Some((name, host)) = value.split_once('@') else {
        return false;
    };
    !host.contains('@')
        && (1..=64).contains(&name.len())
        && (1..=189).contains(&host.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-'))
}

fn valid_capability(name: &str, value: &CapabilityValue) -> bool {
    let valid_name = (1..=64).contains(&name.len())
        && name.bytes().next().is_some_and(|b| b.is_ascii_lowercase())
        && name.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'_' | b'.' | b'-')
        });
    valid_name
        && match value {
            CapabilityValue::Bool(_) | CapabilityValue::Uint(_) => true,
            CapabilityValue::Text(text) => text.len() <= 256,
            CapabilityValue::TextList(values) => {
                values.len() <= 32
                    && values.iter().all(|text| text.len() <= 256)
                    && values.iter().collect::<BTreeSet<_>>().len() == values.len()
            }
        }
}

#[derive(Debug)]
enum Message {
    Announcement(Announcement),
    Withdrawal(Withdrawal),
}

impl Message {
    fn endpoint_id(&self) -> EndpointId {
        match self {
            Self::Announcement(value) => value.endpoint_id,
            Self::Withdrawal(value) => value.endpoint_id,
        }
    }

    fn fleet_id(&self) -> [u8; 32] {
        match self {
            Self::Announcement(value) => value.fleet_id,
            Self::Withdrawal(value) => value.fleet_id,
        }
    }
}

fn encode_announcement(value: &Announcement) -> Vec<u8> {
    encode_map(vec![
        field("version", encode_uint(1)),
        field("kind", encode_text("announcement")),
        field("fleet_id", encode_bytes(&value.fleet_id)),
        field("endpoint_id", encode_bytes(value.endpoint_id.as_bytes())),
        field("node_name", encode_text(&value.node_name)),
        field("partisan_ip", encode_bytes(&value.partisan_ip)),
        field(
            "partisan_port",
            encode_uint(value.partisan_port.get().into()),
        ),
        field("sequence", encode_uint(value.sequence)),
        field("ttl_ms", encode_uint(value.ttl_ms)),
        field("capabilities", encode_capabilities(&value.capabilities)),
        field(
            "load",
            encode_map(vec![
                field("running", encode_uint(value.load.running)),
                field("capacity", encode_uint(value.load.capacity)),
            ]),
        ),
    ])
}

fn encode_withdrawal(value: &Withdrawal) -> Vec<u8> {
    encode_map(vec![
        field("version", encode_uint(1)),
        field("kind", encode_text("withdrawal")),
        field("fleet_id", encode_bytes(&value.fleet_id)),
        field("endpoint_id", encode_bytes(value.endpoint_id.as_bytes())),
        field("sequence", encode_uint(value.sequence)),
    ])
}

fn encode_capabilities(values: &BTreeMap<String, CapabilityValue>) -> Vec<u8> {
    encode_map(
        values
            .iter()
            .map(|(name, value)| field(name, encode_capability(value)))
            .collect(),
    )
}

fn encode_capability(value: &CapabilityValue) -> Vec<u8> {
    match value {
        CapabilityValue::Bool(false) => vec![0xf4],
        CapabilityValue::Bool(true) => vec![0xf5],
        CapabilityValue::Uint(value) => encode_uint(*value),
        CapabilityValue::Text(value) => encode_text(value),
        CapabilityValue::TextList(values) => {
            let mut encoded = encode_head(4, values.len() as u64);
            for value in values {
                encoded.extend(encode_text(value));
            }
            encoded
        }
    }
}

fn encode_envelope(body: &[u8], signature: &[u8; 64]) -> Vec<u8> {
    encode_map(vec![
        field("body", encode_bytes(body)),
        field("signature", encode_bytes(signature)),
    ])
}

fn field(name: &str, value: Vec<u8>) -> (Vec<u8>, Vec<u8>) {
    (encode_text(name), value)
}

fn encode_map(mut fields: Vec<(Vec<u8>, Vec<u8>)>) -> Vec<u8> {
    fields.sort_by(|(a, _), (b, _)| canonical_cmp(a, b));
    let mut encoded = encode_head(5, fields.len() as u64);
    for (key, value) in fields {
        encoded.extend(key);
        encoded.extend(value);
    }
    encoded
}

fn canonical_cmp(a: &[u8], b: &[u8]) -> Ordering {
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

fn encode_uint(value: u64) -> Vec<u8> {
    encode_head(0, value)
}

fn encode_text(value: &str) -> Vec<u8> {
    let mut encoded = encode_head(3, value.len() as u64);
    encoded.extend_from_slice(value.as_bytes());
    encoded
}

fn encode_bytes(value: &[u8]) -> Vec<u8> {
    let mut encoded = encode_head(2, value.len() as u64);
    encoded.extend_from_slice(value);
    encoded
}

fn encode_head(major: u8, value: u64) -> Vec<u8> {
    let prefix = major << 5;
    match value {
        0..=23 => vec![prefix | value as u8],
        24..=0xff => vec![prefix | 24, value as u8],
        0x100..=0xffff => {
            let mut out = vec![prefix | 25];
            out.extend_from_slice(&(value as u16).to_be_bytes());
            out
        }
        0x1_0000..=0xffff_ffff => {
            let mut out = vec![prefix | 26];
            out.extend_from_slice(&(value as u32).to_be_bytes());
            out
        }
        _ => {
            let mut out = vec![prefix | 27];
            out.extend_from_slice(&value.to_be_bytes());
            out
        }
    }
}

fn decode_envelope(bytes: &[u8]) -> Result<(Vec<u8>, Signature), Error> {
    let mut reader = Reader::new(bytes);
    let len = reader.map_len()?;
    if len != 2 {
        return Err(Error::Malformed);
    }
    let mut previous = None;
    let mut body = None;
    let mut signature = None;
    for _ in 0..len {
        let key = reader.canonical_key(&mut previous)?;
        match key.as_str() {
            "body" => body = Some(reader.bytes()?.to_vec()),
            "signature" => {
                let bytes: [u8; 64] = reader.bytes()?.try_into().map_err(|_| Error::Malformed)?;
                signature =
                    Some(Signature::try_from(bytes.as_slice()).map_err(|_| Error::Malformed)?);
            }
            _ => return Err(Error::Malformed),
        }
    }
    reader.finish()?;
    let body = body.ok_or(Error::Malformed)?;
    let signature = signature.ok_or(Error::Malformed)?;
    if encode_envelope(&body, &signature.to_bytes()) != bytes {
        return Err(Error::Malformed);
    }
    Ok((body, signature))
}

fn decode_message(bytes: &[u8]) -> Result<Message, Error> {
    let mut reader = Reader::new(bytes);
    let len = reader.map_len()?;
    let mut previous = None;
    let mut version = None;
    let mut kind = None;
    let mut fleet_id = None;
    let mut endpoint_id = None;
    let mut node_name = None;
    let mut partisan_ip = None;
    let mut partisan_port = None;
    let mut sequence = None;
    let mut ttl_ms = None;
    let mut capabilities = None;
    let mut load = None;
    for _ in 0..len {
        let key = reader.canonical_key(&mut previous)?;
        match key.as_str() {
            "version" => version = Some(reader.uint()?),
            "kind" => kind = Some(reader.text()?.to_owned()),
            "fleet_id" => fleet_id = Some(read_array::<32>(&mut reader)?),
            "endpoint_id" => {
                let bytes = read_array::<32>(&mut reader)?;
                endpoint_id = Some(EndpointId::from_bytes(&bytes).map_err(|_| Error::Malformed)?);
            }
            "node_name" => node_name = Some(reader.text()?.to_owned()),
            "partisan_ip" => partisan_ip = Some(read_array::<4>(&mut reader)?),
            "partisan_port" => {
                let port = u16::try_from(reader.uint()?).map_err(|_| Error::InvalidRecord)?;
                partisan_port = Some(NonZeroU16::new(port).ok_or(Error::InvalidRecord)?);
            }
            "sequence" => sequence = Some(reader.uint()?),
            "ttl_ms" => ttl_ms = Some(reader.uint()?),
            "capabilities" => capabilities = Some(decode_capabilities(&mut reader)?),
            "load" => load = Some(decode_load(&mut reader)?),
            _ => return Err(Error::Malformed),
        }
    }
    reader.finish()?;
    match version.ok_or(Error::Malformed)? {
        1 => {}
        _ => return Err(Error::UnsupportedVersion),
    }
    let fleet_id = fleet_id.ok_or(Error::Malformed)?;
    let endpoint_id = endpoint_id.ok_or(Error::Malformed)?;
    let sequence = sequence.ok_or(Error::Malformed)?;
    let message = match kind.as_deref() {
        Some("announcement") if len == 11 => Message::Announcement(Announcement {
            fleet_id,
            endpoint_id,
            node_name: node_name.ok_or(Error::Malformed)?,
            partisan_ip: partisan_ip.ok_or(Error::Malformed)?,
            partisan_port: partisan_port.ok_or(Error::Malformed)?,
            sequence,
            ttl_ms: ttl_ms.ok_or(Error::Malformed)?,
            capabilities: capabilities.ok_or(Error::Malformed)?,
            load: load.ok_or(Error::Malformed)?,
        }),
        Some("withdrawal") if len == 5 => Message::Withdrawal(Withdrawal {
            fleet_id,
            endpoint_id,
            sequence,
        }),
        Some("announcement" | "withdrawal") => return Err(Error::Malformed),
        _ => return Err(Error::InvalidRecord),
    };
    let canonical = match &message {
        Message::Announcement(value) => encode_announcement(value),
        Message::Withdrawal(value) => encode_withdrawal(value),
    };
    if canonical != bytes {
        return Err(Error::Malformed);
    }
    Ok(message)
}

fn decode_load(reader: &mut Reader<'_>) -> Result<Load, Error> {
    let len = reader.map_len()?;
    if len != 2 {
        return Err(Error::Malformed);
    }
    let mut previous = None;
    let mut running = None;
    let mut capacity = None;
    for _ in 0..len {
        match reader.canonical_key(&mut previous)?.as_str() {
            "running" => running = Some(reader.uint()?),
            "capacity" => capacity = Some(reader.uint()?),
            _ => return Err(Error::Malformed),
        }
    }
    Ok(Load {
        running: running.ok_or(Error::Malformed)?,
        capacity: capacity.ok_or(Error::Malformed)?,
    })
}

fn decode_capabilities(
    reader: &mut Reader<'_>,
) -> Result<BTreeMap<String, CapabilityValue>, Error> {
    let len = reader.map_len()?;
    if len > 32 {
        return Err(Error::InvalidRecord);
    }
    let mut previous = None;
    let mut values = BTreeMap::new();
    for _ in 0..len {
        let key = reader.canonical_key(&mut previous)?;
        values.insert(key, reader.capability()?);
    }
    Ok(values)
}

fn read_array<const N: usize>(reader: &mut Reader<'_>) -> Result<[u8; N], Error> {
    reader.bytes()?.try_into().map_err(|_| Error::Malformed)
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn finish(&self) -> Result<(), Error> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err(Error::Malformed)
        }
    }

    fn uint(&mut self) -> Result<u64, Error> {
        self.head(0)
    }

    fn map_len(&mut self) -> Result<usize, Error> {
        self.length(5)
    }

    fn text(&mut self) -> Result<&'a str, Error> {
        let len = self.length(3)?;
        std::str::from_utf8(self.take(len)?).map_err(|_| Error::Malformed)
    }

    fn bytes(&mut self) -> Result<&'a [u8], Error> {
        let len = self.length(2)?;
        self.take(len)
    }

    fn canonical_key(&mut self, previous: &mut Option<Vec<u8>>) -> Result<String, Error> {
        let start = self.offset;
        let key = self.text()?.to_owned();
        let encoded = self.bytes[start..self.offset].to_vec();
        if previous
            .as_ref()
            .is_some_and(|last| canonical_cmp(last, &encoded) != Ordering::Less)
        {
            return Err(Error::Malformed);
        }
        *previous = Some(encoded);
        Ok(key)
    }

    fn capability(&mut self) -> Result<CapabilityValue, Error> {
        let byte = *self.bytes.get(self.offset).ok_or(Error::Malformed)?;
        match byte {
            0xf4 => {
                self.offset += 1;
                Ok(CapabilityValue::Bool(false))
            }
            0xf5 => {
                self.offset += 1;
                Ok(CapabilityValue::Bool(true))
            }
            _ => match byte >> 5 {
                0 => Ok(CapabilityValue::Uint(self.uint()?)),
                3 => Ok(CapabilityValue::Text(self.text()?.to_owned())),
                4 => {
                    let len = self.length(4)?;
                    if len > 32 {
                        return Err(Error::InvalidRecord);
                    }
                    let values = (0..len)
                        .map(|_| self.text().map(str::to_owned))
                        .collect::<Result<Vec<_>, _>>()?;
                    Ok(CapabilityValue::TextList(values))
                }
                _ => Err(Error::Malformed),
            },
        }
    }

    fn length(&mut self, major: u8) -> Result<usize, Error> {
        self.head(major)?.try_into().map_err(|_| Error::Malformed)
    }

    fn head(&mut self, expected_major: u8) -> Result<u64, Error> {
        let initial = *self.take(1)?.first().ok_or(Error::Malformed)?;
        if initial >> 5 != expected_major {
            return Err(Error::Malformed);
        }
        let additional = initial & 0x1f;
        match additional {
            value @ 0..=23 => Ok(u64::from(value)),
            24 => {
                let value = u64::from(self.take(1)?[0]);
                (value >= 24).then_some(value).ok_or(Error::Malformed)
            }
            25 => {
                let value = u64::from(u16::from_be_bytes(read_array_from(self.take(2)?)?));
                (value > u8::MAX.into())
                    .then_some(value)
                    .ok_or(Error::Malformed)
            }
            26 => {
                let value = u64::from(u32::from_be_bytes(read_array_from(self.take(4)?)?));
                (value > u16::MAX.into())
                    .then_some(value)
                    .ok_or(Error::Malformed)
            }
            27 => {
                let value = u64::from_be_bytes(read_array_from(self.take(8)?)?);
                (value > u32::MAX.into())
                    .then_some(value)
                    .ok_or(Error::Malformed)
            }
            _ => Err(Error::Malformed),
        }
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8], Error> {
        let end = self.offset.checked_add(len).ok_or(Error::Malformed)?;
        let value = self.bytes.get(self.offset..end).ok_or(Error::Malformed)?;
        self.offset = end;
        Ok(value)
    }
}

fn read_array_from<const N: usize>(bytes: &[u8]) -> Result<[u8; N], Error> {
    bytes.try_into().map_err(|_| Error::Malformed)
}

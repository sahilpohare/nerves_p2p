use std::{
    collections::BTreeMap,
    error::Error as StdError,
    fs,
    io::{self, Read, Write},
    net::{Ipv4Addr, SocketAddr, SocketAddrV4},
    num::NonZeroU16,
    path::PathBuf,
    pin::Pin,
    str::FromStr,
    time::{Duration, SystemTime},
};

use futures_lite::StreamExt;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, SecretKey, TransportAddr,
    address_lookup::{DnsAddressLookup, MemoryLookup, PkarrPublisher},
    endpoint::presets,
};
use iroh_discovery::{
    Announcement, AuthorizationTable, CapabilityValue, EnrollmentPolicy, FileSequenceStore, Load,
    Predicate, Registry,
    dist::Event as DistEvent,
    load_or_create_secret, reserve_next, sign_announcement,
    transport::{Subscription, Transport},
};
use iroh_gossip::TopicId;
use iroh_mainline_address_lookup::DhtAddressLookup;
use iroh_mdns_address_lookup::{DiscoveryEvent, MdnsAddressLookup};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    sync::mpsc,
    time::{interval, timeout},
};

const MAX_FRAME_SIZE: usize = 64 * 1024;
const EVENT_QUEUE: usize = 64;

#[derive(Deserialize)]
struct Request {
    id: Value,
    #[serde(flatten)]
    command: Command,
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Command {
    Identity,
    Authorize {
        endpoint_id: String,
        node_name: String,
    },
    NetworkStart {
        #[serde(default)]
        bootstrap: Option<JsonEndpointAddr>,
        /// Known bootstrap IDs are resolved by configured address lookups. DHT is
        /// address lookup for these IDs, not capability lookup.
        #[serde(default)]
        bootstrap_endpoint_ids: Vec<String>,
        #[serde(default, alias = "lan_discovery")]
        mdns: bool,
        #[serde(default)]
        dht: bool,
        #[serde(default = "default_enabled")]
        dns: bool,
        #[serde(default = "default_enabled")]
        relay: bool,
    },
    Publish {
        ttl_ms: u64,
        partisan_ip: String,
        partisan_port: u16,
        capabilities: BTreeMap<String, Value>,
        load: JsonLoad,
    },
    Ingest {
        envelope: String,
        endpoint_id: String,
        node_name: String,
    },
    Find {
        #[serde(default)]
        predicates: Vec<JsonPredicate>,
    },
    DistListen {
        node_name: String,
    },
    DistConnect {
        from_node: String,
        target_node: String,
    },
    DistSend {
        stream_id: u64,
        bytes: String,
    },
    DistCredit {
        stream_id: u64,
        bytes: usize,
    },
    DistClose {
        stream_id: u64,
    },
    Shutdown,
}

#[derive(Deserialize, Serialize)]
struct JsonEndpointAddr {
    endpoint_id: String,
    direct_addresses: Vec<String>,
}

#[derive(Deserialize)]
struct JsonLoad {
    running: u64,
    capacity: u64,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum JsonPredicate {
    Equals { name: String, value: Value },
    AtLeast { name: String, value: u64 },
    Contains { name: String, value: String },
}

enum Frame {
    Eof,
    Oversized,
    Payload(Vec<u8>),
}

struct Network {
    transport: Transport,
    subscription: Subscription,
    mdns_events: Option<Pin<Box<dyn futures_lite::Stream<Item = DiscoveryEvent> + Send>>>,
}

struct State {
    fleet: [u8; 32],
    outbound: FileSequenceStore,
    registry: Registry<FileSequenceStore>,
    network: Option<Network>,
    dist_events: mpsc::Sender<DistEvent>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn StdError>> {
    let mut args = std::env::args_os().skip(1);
    let data_dir = PathBuf::from(args.next().ok_or("missing data directory")?);
    let fleet_arg = args
        .next()
        .ok_or("missing fleet id")?
        .into_string()
        .map_err(|_| "fleet id must be UTF-8")?;
    let fleet: [u8; 32] = hex::decode(fleet_arg)?
        .try_into()
        .map_err(|_| "fleet id must be 32 bytes")?;
    let node_name = args
        .next()
        .ok_or("missing node name")?
        .into_string()
        .map_err(|_| "node name must be UTF-8")?;
    if args.next().is_some() {
        return Err("unexpected argument".into());
    }
    fs::create_dir_all(&data_dir)?;
    let secret = load_or_create_secret(&data_dir.join("secret.key"))?;
    let endpoint = secret.public();
    let authorization = AuthorizationTable::new([(endpoint, node_name.clone())])?;
    let (dist_events, mut event_rx) = mpsc::channel(EVENT_QUEUE);
    let mut state = State {
        fleet,
        outbound: FileSequenceStore::open(data_dir.join("outbound.sequences"))?,
        registry: Registry::new(
            fleet,
            authorization,
            FileSequenceStore::open(data_dir.join("inbound.sequences"))?,
        )
        .with_enrollment_policy(EnrollmentPolicy::SignedFleet),
        network: None,
        dist_events,
    };
    let started = SystemTime::now();
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let (frame_tx, mut frame_rx) = mpsc::channel(16);
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut input = stdin.lock();
        loop {
            let frame = read_frame(&mut input);
            let stop = !matches!(frame, Ok(Frame::Payload(_) | Frame::Oversized));
            if frame_tx.blocking_send(frame).is_err() || stop {
                break;
            }
        }
    });
    let mut network_tick = interval(Duration::from_millis(100));

    let shutdown = loop {
        tokio::select! {
            frame = frame_rx.recv() => match frame.transpose()? {
                None | Some(Frame::Eof) => break false,
                Some(Frame::Oversized) => write_json(
                    &mut output,
                    &json!({"id": null, "ok": false, "error": "frame_too_large"}),
                )?,
                Some(Frame::Payload(payload)) => {
                let request = match serde_json::from_slice::<Request>(&payload) {
                    Ok(request) => request,
                    Err(_) => {
                        write_json(
                            &mut output,
                            &json!({"id": null, "ok": false, "error": "malformed"}),
                        )?;
                        continue;
                    }
                };
                let id = request.id.clone();
                let shutdown = matches!(&request.command, Command::Shutdown);
                let response = match handle(
                    request.command,
                    &secret,
                    &node_name,
                    &mut state,
                    now_ms(started),
                )
                .await
                {
                    Ok(result) => json!({"id": id, "ok": true, "result": result}),
                    Err(error) => json!({"id": id, "ok": false, "error": error}),
                };
                write_json(&mut output, &response)?;
                if shutdown {
                    break true;
                }
                }
            },
            event = event_rx.recv() => if let Some(event) = event {
                write_json(&mut output, &dist_event_json(event))?;
            },
            _ = network_tick.tick() => {
                let now = now_ms(started);
                if let Some(network) = &mut state.network {
                    let _ = receive_mdns_peers(network).await;
                    let _ = poll_announcements(network, &mut state.registry, now).await;
                }
                sync_dist_bindings(&mut state, now);
            },
        }
    };
    if let Some(network) = state.network {
        network.shutdown().await?;
    }
    let _ = shutdown;
    Ok(())
}

async fn handle(
    command: Command,
    secret: &SecretKey,
    node_name: &str,
    state: &mut State,
    now: u64,
) -> Result<Value, String> {
    if let Some(network) = &mut state.network {
        receive_mdns_peers(network).await?;
    }
    match command {
        Command::Identity => Ok(json!({
            "endpoint_id": secret.public().to_string(),
            "endpoint_address": state.network.as_ref().map(|network| json_endpoint_addr(network.transport.endpoint_addr()))
        })),
        Command::Authorize {
            endpoint_id,
            node_name,
        } => {
            let endpoint = EndpointId::from_str(&endpoint_id).map_err(|_| "malformed")?;
            state
                .registry
                .authorize(endpoint, node_name)
                .map_err(error_name)?;
            Ok(json!({"authorized": true}))
        }
        Command::NetworkStart {
            bootstrap,
            bootstrap_endpoint_ids,
            mdns,
            dht,
            dns,
            relay,
        } => {
            if state.network.is_some() {
                return Err("network_started".into());
            }
            let explicit_bootstrap = bootstrap.is_some();
            let known_bootstrap = !bootstrap_endpoint_ids.is_empty();
            let lookup = MemoryLookup::new();
            let explicit_id = bootstrap
                .map(|address| {
                    let address = parse_endpoint_addr(address)?;
                    let id = address.id;
                    lookup.add_endpoint_info(address);
                    Ok::<_, &'static str>(id)
                })
                .transpose()?;
            let mut bootstrap_ids = bootstrap_endpoint_ids
                .into_iter()
                .map(|id| EndpointId::from_str(&id).map_err(|_| "malformed"))
                .collect::<Result<Vec<_>, _>>()?;
            if let Some(id) = explicit_id {
                bootstrap_ids.push(id);
            }
            bootstrap_ids.sort_unstable();
            bootstrap_ids.dedup();

            let mut endpoint_builder = Endpoint::builder(presets::Minimal)
                .secret_key(secret.clone())
                .address_lookup(lookup.clone());
            if dns {
                endpoint_builder = endpoint_builder
                    .address_lookup(PkarrPublisher::n0_dns())
                    .address_lookup(DnsAddressLookup::n0_dns());
            }
            let endpoint = endpoint_builder
                .relay_mode(if relay {
                    RelayMode::Default
                } else {
                    RelayMode::Disabled
                })
                .bind_addr(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0))
                .map_err(|_| "network_failed")?
                .bind()
                .await
                .map_err(|_| "network_failed")?;
            let mdns_lookup = mdns
                .then(|| {
                    let fleet = hex::encode(state.fleet);
                    MdnsAddressLookup::builder()
                        .service_name(format!("erp-{}", &fleet[..8]))
                        .build(endpoint.id())
                        .map_err(|_| "network_failed")
                })
                .transpose()?;
            if let Some(lookup) = &mdns_lookup {
                endpoint
                    .address_lookup()
                    .map_err(|_| "network_failed")?
                    .add(lookup.clone());
            }
            if dht {
                let lookup = DhtAddressLookup::builder()
                    .secret_key(secret.clone())
                    .build()
                    .map_err(|_| "network_failed")?;
                endpoint
                    .address_lookup()
                    .map_err(|_| "network_failed")?
                    .add(lookup);
            }
            let mdns_events = match mdns_lookup {
                Some(lookup) => Some(Box::pin(lookup.subscribe().await)
                    as Pin<Box<dyn futures_lite::Stream<Item = DiscoveryEvent> + Send>>),
                None => None,
            };
            let transport = Transport::spawn_with_dist(endpoint, state.dist_events.clone());
            let mut subscription = transport
                .subscribe(TopicId::from(state.fleet), bootstrap_ids.clone())
                .await
                .map_err(|_| "network_failed")?;
            if !bootstrap_ids.is_empty() {
                timeout(Duration::from_secs(5), subscription.joined())
                    .await
                    .map_err(|_| "network_failed")?
                    .map_err(|_| "network_failed")?;
            }
            let endpoint_address = json_endpoint_addr(transport.endpoint_addr());
            state.network = Some(Network {
                transport,
                subscription,
                mdns_events,
            });
            let discovery_mechanisms = [
                (explicit_bootstrap, "bootstrap"),
                (known_bootstrap, "bootstrap_endpoint_ids"),
                (mdns, "mdns"),
                (dht, "dht"),
                (dns, "dns"),
                (relay, "relay"),
            ]
            .into_iter()
            .filter_map(|(enabled, name)| enabled.then_some(name))
            .collect::<Vec<_>>();
            Ok(json!({
                "endpoint_address": endpoint_address,
                "discovery_mechanisms": discovery_mechanisms
            }))
        }
        Command::Publish {
            ttl_ms,
            partisan_ip,
            partisan_port,
            capabilities,
            load,
        } => {
            let partisan_ip = partisan_ip
                .parse::<Ipv4Addr>()
                .map_err(|_| "invalid_record")?
                .octets();
            let partisan_port = NonZeroU16::new(partisan_port).ok_or("invalid_record")?;
            let capabilities = capabilities
                .into_iter()
                .map(|(name, value)| json_capability(value).map(|value| (name, value)))
                .collect::<Result<_, _>>()?;
            let sequence =
                reserve_next(&mut state.outbound, secret.public()).map_err(error_name)?;
            let announcement = Announcement {
                fleet_id: state.fleet,
                endpoint_id: secret.public(),
                node_name: node_name.to_owned(),
                partisan_ip,
                partisan_port,
                sequence,
                ttl_ms,
                capabilities,
                load: Load {
                    running: load.running,
                    capacity: load.capacity,
                },
            };
            let envelope = sign_announcement(&announcement, secret).map_err(error_name)?;
            state.registry.receive(&envelope, now).map_err(error_name)?;
            sync_dist_bindings(state, now);
            if let Some(network) = &mut state.network {
                network
                    .subscription
                    .broadcast(envelope.clone())
                    .await
                    .map_err(|_| "network_failed")?;
            }
            Ok(json!({"sequence": sequence, "envelope": hex::encode(envelope)}))
        }
        Command::Ingest {
            envelope,
            endpoint_id,
            node_name,
        } => {
            let endpoint = EndpointId::from_str(&endpoint_id).map_err(|_| "malformed")?;
            state
                .registry
                .authorize(endpoint, node_name)
                .map_err(error_name)?;
            state
                .registry
                .receive(&hex::decode(envelope).map_err(|_| "malformed")?, now)
                .map_err(error_name)?;
            sync_dist_bindings(state, now);
            Ok(json!({"accepted": true}))
        }
        Command::Find { predicates } => {
            if let Some(network) = &mut state.network {
                receive_announcements(network, &mut state.registry, now).await?;
            }
            sync_dist_bindings(state, now);
            let predicates = predicates
                .into_iter()
                .map(json_predicate)
                .collect::<Result<Vec<_>, _>>()?;
            let peers = state.registry
                .find(&predicates, now)
                .map_err(error_name)?
                .into_iter()
                .map(|peer| {
                    json!({
                        "endpoint_id": peer.endpoint_id.to_string(),
                        "node_name": peer.node_name,
                        "partisan_ip": Ipv4Addr::from(peer.partisan_ip).to_string(),
                        "partisan_port": peer.partisan_port.get(),
                        "sequence": peer.sequence,
                        "capabilities": peer.capabilities.into_iter().map(|(name, value)| (name, capability_json(value))).collect::<BTreeMap<_, _>>()
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"peers": peers}))
        }
        Command::DistListen { node_name: listen } => {
            if listen != node_name {
                return Err("wrong_target".into());
            }
            if let Some(network) = &mut state.network {
                receive_announcements(network, &mut state.registry, now).await?;
            }
            sync_dist_bindings(state, now);
            state
                .network
                .as_ref()
                .ok_or("network_not_started")?
                .transport
                .dist()
                .listen(&listen)
                .map_err(|error| error.to_string())?;
            Ok(json!({}))
        }
        Command::DistConnect {
            from_node,
            target_node,
        } => {
            if from_node != node_name {
                return Err("unauthorized_source".into());
            }
            if let Some(network) = &mut state.network {
                receive_announcements(network, &mut state.registry, now).await?;
            }
            sync_dist_bindings(state, now);
            let stream_id = state
                .network
                .as_ref()
                .ok_or("network_not_started")?
                .transport
                .dist()
                .connect(from_node, target_node)
                .await
                .map_err(|error| error.to_string())?;
            Ok(json!({"stream_id": stream_id}))
        }
        Command::DistSend { stream_id, bytes } => {
            let bytes = hex::decode(bytes).map_err(|_| "malformed")?;
            state
                .network
                .as_ref()
                .ok_or("network_not_started")?
                .transport
                .dist()
                .send(stream_id, bytes)
                .map_err(|error| error.to_string())?;
            Ok(json!({}))
        }
        Command::DistCredit { stream_id, bytes } => {
            state
                .network
                .as_ref()
                .ok_or("network_not_started")?
                .transport
                .dist()
                .credit(stream_id, bytes)
                .map_err(|error| error.to_string())?;
            Ok(json!({}))
        }
        Command::DistClose { stream_id } => {
            state
                .network
                .as_ref()
                .ok_or("network_not_started")?
                .transport
                .dist()
                .close(stream_id)
                .map_err(|error| error.to_string())?;
            Ok(json!({}))
        }
        Command::Shutdown => Ok(json!({})),
    }
}

impl Network {
    async fn shutdown(self) -> Result<(), Box<dyn StdError>> {
        self.transport.shutdown().await?;
        Ok(())
    }
}

async fn receive_mdns_peers(network: &mut Network) -> Result<(), String> {
    let Some(events) = &mut network.mdns_events else {
        return Ok(());
    };
    while let Ok(Some(event)) = timeout(Duration::from_millis(1), events.next()).await {
        if let DiscoveryEvent::Discovered { endpoint_info, .. } = event {
            network
                .subscription
                .join_peers(vec![endpoint_info.endpoint_id])
                .await
                .map_err(|_| "network_failed")?;
        }
    }
    Ok(())
}

fn default_enabled() -> bool {
    true
}

fn parse_endpoint_addr(value: JsonEndpointAddr) -> Result<EndpointAddr, &'static str> {
    let id = EndpointId::from_str(&value.endpoint_id).map_err(|_| "malformed")?;
    let addresses = value
        .direct_addresses
        .into_iter()
        .map(|address| {
            address
                .parse::<SocketAddr>()
                .map(TransportAddr::Ip)
                .map_err(|_| "malformed")
        })
        .collect::<Result<Vec<_>, _>>()?;
    if addresses.is_empty() {
        return Err("malformed");
    }
    Ok(EndpointAddr::from_parts(id, addresses))
}

fn json_endpoint_addr(value: EndpointAddr) -> JsonEndpointAddr {
    JsonEndpointAddr {
        endpoint_id: value.id.to_string(),
        direct_addresses: value.ip_addrs().map(ToString::to_string).collect(),
    }
}

async fn receive_announcements(
    network: &mut Network,
    registry: &mut Registry<FileSequenceStore>,
    now: u64,
) -> Result<(), String> {
    let mut wait = Duration::from_millis(500);
    while let Ok(received) = timeout(wait, network.subscription.receive()).await {
        let Some(envelope) = received.map_err(|_| "network_failed")? else {
            break;
        };
        let _ = registry.receive(&envelope, now);
        wait = Duration::from_millis(1);
    }
    Ok(())
}

async fn poll_announcements(
    network: &mut Network,
    registry: &mut Registry<FileSequenceStore>,
    now: u64,
) -> Result<(), String> {
    while let Ok(received) = timeout(Duration::from_millis(1), network.subscription.receive()).await
    {
        let Some(envelope) = received.map_err(|_| "network_failed")? else {
            break;
        };
        let _ = registry.receive(&envelope, now);
    }
    Ok(())
}

fn sync_dist_bindings(state: &mut State, now: u64) {
    if let Some(network) = &state.network {
        network
            .transport
            .dist()
            .replace_bindings(state.registry.bindings(now));
    }
}

fn dist_event_json(event: DistEvent) -> Value {
    match event {
        DistEvent::Incoming {
            stream_id,
            from_node,
            target_node,
        } => json!({
            "event": "dist_incoming",
            "stream_id": stream_id,
            "from_node": from_node,
            "target_node": target_node
        }),
        DistEvent::Connected {
            stream_id,
            target_node,
        } => json!({
            "event": "dist_connected",
            "stream_id": stream_id,
            "target_node": target_node
        }),
        DistEvent::Data { stream_id, bytes } => json!({
            "event": "dist_data",
            "stream_id": stream_id,
            "bytes": hex::encode(bytes)
        }),
        DistEvent::Credit { stream_id, bytes } => json!({
            "event": "dist_credit",
            "stream_id": stream_id,
            "bytes": bytes
        }),
        DistEvent::Closed { stream_id, reason } => json!({
            "event": "dist_closed",
            "stream_id": stream_id,
            "reason": reason
        }),
    }
}

fn json_capability(value: Value) -> Result<CapabilityValue, &'static str> {
    match value {
        Value::Bool(value) => Ok(CapabilityValue::Bool(value)),
        Value::Number(value) => value
            .as_u64()
            .map(CapabilityValue::Uint)
            .ok_or("invalid_capability"),
        Value::String(value) => Ok(CapabilityValue::Text(value)),
        Value::Array(values) => values
            .into_iter()
            .map(|value| match value {
                Value::String(value) => Ok(value),
                _ => Err("invalid_capability"),
            })
            .collect::<Result<_, _>>()
            .map(CapabilityValue::TextList),
        _ => Err("invalid_capability"),
    }
}

fn capability_json(value: CapabilityValue) -> Value {
    match value {
        CapabilityValue::Bool(value) => json!(value),
        CapabilityValue::Uint(value) => json!(value),
        CapabilityValue::Text(value) => json!(value),
        CapabilityValue::TextList(value) => json!(value),
    }
}

fn json_predicate(value: JsonPredicate) -> Result<Predicate, &'static str> {
    match value {
        JsonPredicate::Equals { name, value } => {
            Ok(Predicate::Equals(name, json_capability(value)?))
        }
        JsonPredicate::AtLeast { name, value } => Ok(Predicate::AtLeast(name, value)),
        JsonPredicate::Contains { name, value } => Ok(Predicate::Contains(name, value)),
    }
}

fn error_name(error: iroh_discovery::Error) -> String {
    error.to_string()
}

fn now_ms(started: SystemTime) -> u64 {
    started
        .elapsed()
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn read_frame(input: &mut impl Read) -> io::Result<Frame> {
    let mut length = [0; 4];
    match input.read_exact(&mut length) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(Frame::Eof),
        Err(error) => return Err(error),
    }
    let length = u32::from_be_bytes(length) as usize;
    if length > MAX_FRAME_SIZE {
        io::copy(&mut input.take(length as u64), &mut io::sink())?;
        return Ok(Frame::Oversized);
    }
    let mut payload = vec![0; length];
    input.read_exact(&mut payload)?;
    Ok(Frame::Payload(payload))
}

fn write_json(output: &mut impl Write, value: &Value) -> io::Result<()> {
    let mut payload = serde_json::to_vec(value)?;
    if payload.len() > MAX_FRAME_SIZE {
        payload = serde_json::to_vec(&json!({
            "id": value.get("id").unwrap_or(&Value::Null),
            "ok": false,
            "error": "frame_too_large"
        }))?;
    }
    output.write_all(&(payload.len() as u32).to_be_bytes())?;
    output.write_all(&payload)?;
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn p_network_options_are_absent_c_decode_start_request_q_defaults_are_deterministic() {
        let defaults: Request =
            serde_json::from_value(json!({"id": 1, "command": "network_start"}))
                .expect("default lookup config");
        assert!(matches!(
            defaults.command,
            Command::NetworkStart {
                bootstrap: None,
                bootstrap_endpoint_ids,
                mdns: false,
                dht: false,
                dns: true,
                relay: true,
            } if bootstrap_endpoint_ids.is_empty()
        ));
    }

    #[test]
    fn p_all_discovery_settings_are_false_c_decode_start_request_q_every_mechanism_is_disabled() {
        let request: Request = serde_json::from_value(json!({
            "id": 1,
            "command": "network_start",
            "mdns": false,
            "dht": false,
            "dns": false,
            "relay": false
        }))
        .expect("disabled lookup config");
        assert!(matches!(
            request.command,
            Command::NetworkStart {
                bootstrap: None,
                bootstrap_endpoint_ids,
                mdns: false,
                dht: false,
                dns: false,
                relay: false,
            } if bootstrap_endpoint_ids.is_empty()
        ));
    }

    #[test]
    fn p_all_discovery_settings_are_true_c_decode_start_request_q_every_mechanism_is_enabled() {
        let explicit = SecretKey::from_bytes(&[1; 32]).public();
        let known = SecretKey::from_bytes(&[2; 32]).public();
        let request: Request = serde_json::from_value(json!({
            "id": 1,
            "command": "network_start",
            "bootstrap": {
                "endpoint_id": explicit.to_string(),
                "direct_addresses": ["127.0.0.1:7777"]
            },
            "bootstrap_endpoint_ids": [known.to_string()],
            "mdns": true,
            "dht": true,
            "dns": true,
            "relay": true
        }))
        .expect("valid lookup config");
        let Command::NetworkStart {
            bootstrap,
            bootstrap_endpoint_ids,
            mdns,
            dht,
            dns,
            relay,
        } = request.command
        else {
            panic!("network_start command");
        };
        assert_eq!(
            bootstrap.expect("explicit fallback").endpoint_id,
            explicit.to_string()
        );
        assert_eq!(bootstrap_endpoint_ids, [known.to_string()]);
        assert!(mdns && dht && dns && relay);
    }
}

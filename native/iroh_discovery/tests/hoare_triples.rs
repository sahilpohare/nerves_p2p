use std::collections::BTreeMap;
use std::num::NonZeroU16;

use iroh::SecretKey;
use iroh_discovery::{
    Announcement, AuthorizationTable, CapabilityValue, EnrollmentPolicy, Error, Load,
    MemorySequenceStore, Predicate, Registry, SequenceStore, Withdrawal, sign_announcement,
    sign_withdrawal,
};

const FLEET: [u8; 32] = [7; 32];

fn key(byte: u8) -> SecretKey {
    SecretKey::from_bytes(&[byte; 32])
}

fn announcement(secret: &SecretKey, sequence: u64, running: u64, capacity: u64) -> Announcement {
    Announcement {
        fleet_id: FLEET,
        endpoint_id: secret.public(),
        node_name: format!("node{sequence}@fleet.local"),
        partisan_ip: [10, 20, 30, 40],
        partisan_port: NonZeroU16::new(45_123).unwrap(),
        sequence,
        ttl_ms: 5_000,
        capabilities: BTreeMap::from([
            ("camera".into(), CapabilityValue::Bool(true)),
            ("height".into(), CapabilityValue::Uint(1080)),
            ("site".into(), CapabilityValue::Text("north".into())),
            (
                "formats".into(),
                CapabilityValue::TextList(vec!["jpeg".into(), "raw".into()]),
            ),
        ]),
        load: Load { running, capacity },
    }
}

fn registry(entries: &[(SecretKey, &str)]) -> Registry<MemorySequenceStore> {
    let authorization = AuthorizationTable::new(
        entries
            .iter()
            .map(|(secret, name)| (secret.public(), (*name).to_owned())),
    )
    .expect("valid authorization");
    Registry::new(FLEET, authorization, MemorySequenceStore::default())
}

#[test]
fn p_authentic_newer_publication_c_receive_q_watermark_advances_and_record_is_active_until_ttl() {
    let secret = key(1);
    let mut message = announcement(&secret, 1, 1, 4);
    message.node_name = "camera@fleet.local".into();
    let envelope = sign_announcement(&message, &secret).expect("valid message");
    let mut registry = registry(&[(secret, "camera@fleet.local")]);

    registry.receive(&envelope, 100).expect("accepted");

    assert_eq!(registry.store().load(&message.endpoint_id).unwrap(), 1);
    assert_eq!(
        registry
            .active(&message.endpoint_id, 5_099)
            .unwrap()
            .sequence,
        1
    );
    assert!(registry.active(&message.endpoint_id, 5_100).is_none());

    // Authorized traffic over ten messages in one monotonic second is dropped
    // before even a malformed envelope reaches signature verification.
    for _ in 0..9 {
        assert_eq!(registry.receive(&envelope, 200), Err(Error::StaleSequence));
    }
    let mut bad_signature = envelope.clone();
    *bad_signature.last_mut().unwrap() ^= 1;
    assert_eq!(
        registry.receive(&bad_signature, 200),
        Err(Error::RateLimited)
    );
}

#[test]
fn p_envelope_is_tampered_or_impersonated_c_receive_q_rejected_without_state_change() {
    let secret = key(2);
    let impostor = key(3);
    let mut message = announcement(&secret, 1, 0, 2);
    message.node_name = "worker@fleet.local".into();
    let valid = sign_announcement(&message, &secret).unwrap();
    assert_eq!(
        sign_announcement(&message, &impostor),
        Err(Error::InvalidSignature)
    );
    let mut wrong_fleet = message.clone();
    wrong_fleet.fleet_id = [8; 32];
    let wrong_fleet = sign_announcement(&wrong_fleet, &secret).unwrap();
    let mut tampered = valid.clone();
    let body_byte = tampered
        .windows("worker".len())
        .position(|bytes| bytes == b"worker")
        .unwrap();
    tampered[body_byte] = b'W';
    let mut tampered_ip = valid.clone();
    let ip_key = tampered_ip
        .windows("partisan_ip".len())
        .position(|bytes| bytes == b"partisan_ip")
        .unwrap();
    tampered_ip[ip_key + "partisan_ip".len() + 1] ^= 1;
    let mut tampered_port = valid.clone();
    let port_key = tampered_port
        .windows("partisan_port".len())
        .position(|bytes| bytes == b"partisan_port")
        .unwrap();
    tampered_port[port_key + "partisan_port".len() + 2] ^= 1;
    let mut registry = registry(&[(secret, "worker@fleet.local")]);

    assert_eq!(
        registry.receive(&wrong_fleet, 1_000),
        Err(Error::WrongFleet)
    );
    assert_eq!(
        registry.receive(&tampered, 2_000),
        Err(Error::InvalidSignature)
    );
    assert_eq!(
        registry.receive(&tampered_ip, 3_000),
        Err(Error::InvalidSignature)
    );
    assert_eq!(
        registry.receive(&tampered_port, 4_000),
        Err(Error::InvalidSignature)
    );
    assert_eq!(registry.store().load(&message.endpoint_id).unwrap(), 0);
    assert!(registry.active(&message.endpoint_id, 2_000).is_none());
}

#[test]
fn p_watermark_exceeds_replayed_announcement_c_receive_q_rejected_after_withdrawal() {
    let secret = key(4);
    let mut message = announcement(&secret, 1, 0, 1);
    message.node_name = "relay@fleet.local".into();
    let first = sign_announcement(&message, &secret).unwrap();
    let withdrawal = sign_withdrawal(
        &Withdrawal {
            fleet_id: FLEET,
            endpoint_id: secret.public(),
            sequence: 2,
        },
        &secret,
    )
    .unwrap();
    let mut registry = registry(&[(secret, "relay@fleet.local")]);

    registry.receive(&first, 0).unwrap();
    registry.receive(&withdrawal, 1).unwrap();
    assert_eq!(registry.receive(&first, 2), Err(Error::StaleSequence));
    assert_eq!(registry.store().load(&message.endpoint_id).unwrap(), 2);
    assert!(registry.active(&message.endpoint_id, 2).is_none());
}

#[test]
fn p_signed_fleet_policy_and_unknown_endpoint_c_receive_q_only_valid_same_fleet_record_enrolls() {
    let secret = key(5);
    let mut message = announcement(&secret, 1, 0, 1);
    message.node_name = "auto@fleet.local".into();
    let valid = sign_announcement(&message, &secret).unwrap();
    let mut registry = registry(&[]).with_enrollment_policy(EnrollmentPolicy::SignedFleet);

    let mut wrong_fleet = message.clone();
    wrong_fleet.fleet_id = [8; 32];
    assert_eq!(
        registry.receive(&sign_announcement(&wrong_fleet, &secret).unwrap(), 1),
        Err(Error::WrongFleet)
    );
    let mut tampered = valid.clone();
    *tampered.last_mut().unwrap() ^= 1;
    assert_eq!(registry.receive(&tampered, 2), Err(Error::InvalidSignature));
    assert!(registry.active(&secret.public(), 2).is_none());

    registry
        .receive(&valid, 3)
        .expect("signed endpoint enrolls");
    assert_eq!(
        registry.active(&secret.public(), 3).unwrap().node_name,
        "auto@fleet.local"
    );
}

#[test]
fn p_strict_policy_and_unknown_endpoint_c_receive_q_endpoint_is_not_auto_enrolled() {
    let secret = key(6);
    let message = announcement(&secret, 1, 0, 1);
    let envelope = sign_announcement(&message, &secret).unwrap();
    let mut registry = registry(&[]);

    assert_eq!(
        registry.receive(&envelope, 1),
        Err(Error::UnauthorizedEndpoint)
    );
    assert!(registry.active(&secret.public(), 1).is_none());
}

#[test]
fn p_registry_has_mixed_records_c_find_q_fresh_matching_peers_are_deterministically_ordered() {
    let a = key(10);
    let b = key(11);
    let c = key(12);
    let d = key(13);
    let e = key(14);
    let entries = [
        (a.clone(), "a@fleet.local"),
        (b.clone(), "b@fleet.local"),
        (c.clone(), "c@fleet.local"),
        (d.clone(), "d@fleet.local"),
        (e.clone(), "e@fleet.local"),
    ];
    let mut registry = registry(&entries);

    for (secret, node, running, capacity, received_at) in [
        (&a, "a@fleet.local", 1, 4, 1_000),
        (&b, "b@fleet.local", 2, 8, 1_000),
        (&c, "c@fleet.local", 3, 4, 1_000),
        (&d, "d@fleet.local", 4, 4, 1_000),
        (&e, "e@fleet.local", 0, 8, 0),
    ] {
        let mut item = announcement(secret, 1, running, capacity);
        item.node_name = node.into();
        registry
            .receive(&sign_announcement(&item, secret).unwrap(), received_at)
            .unwrap();
    }

    let requirements = [
        Predicate::Equals("camera".into(), CapabilityValue::Bool(true)),
        Predicate::AtLeast("height".into(), 720),
        Predicate::Contains("formats".into(), "raw".into()),
        Predicate::Equals("site".into(), CapabilityValue::Text("north".into())),
    ];
    let found = registry.find(&requirements, 5_000).unwrap();

    // e expired, d is full; a and b have equal ratios, so b wins on spare capacity.
    assert_eq!(
        found.iter().map(|peer| &peer.node_name).collect::<Vec<_>>(),
        [&"b@fleet.local", &"a@fleet.local", &"c@fleet.local"]
    );
    assert_eq!(found[0].partisan_ip, [10, 20, 30, 40]);
    assert_eq!(found[0].partisan_port.get(), 45_123);
    assert_eq!(
        registry.find(&[Predicate::Contains("site".into(), "north".into())], 5_000),
        Err(Error::NoMatchingPeer)
    );
}

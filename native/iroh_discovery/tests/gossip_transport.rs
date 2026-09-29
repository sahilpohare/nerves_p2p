use std::{collections::BTreeMap, net::SocketAddrV4, num::NonZeroU16, time::Duration};

use iroh::{Endpoint, RelayMode, SecretKey, address_lookup::MemoryLookup, endpoint::presets};
use iroh_discovery::{
    Announcement, AuthorizationTable, CapabilityValue, Load, MemorySequenceStore, Registry,
    sign_announcement, transport::Transport,
};
use iroh_gossip::TopicId;
use tokio::time::timeout;

const FLEET: [u8; 32] = [7; 32];

async fn endpoint(secret: SecretKey, lookup: MemoryLookup) -> Endpoint {
    Endpoint::builder(presets::Minimal)
        .secret_key(secret)
        .address_lookup(lookup)
        .relay_mode(RelayMode::Disabled)
        .bind_addr(SocketAddrV4::new(std::net::Ipv4Addr::LOCALHOST, 0))
        .expect("valid bind address")
        .bind()
        .await
        .expect("bind local endpoint")
}

#[tokio::test]
async fn p_bootstrap_id_is_known_c_start_gossip_transport_q_memory_lookup_resolves_and_connects() {
    let sender_lookup = MemoryLookup::new();
    let receiver_lookup = MemoryLookup::new();
    let sender_endpoint = endpoint(SecretKey::from_bytes(&[1; 32]), sender_lookup).await;
    let receiver_endpoint =
        endpoint(SecretKey::from_bytes(&[2; 32]), receiver_lookup.clone()).await;
    receiver_lookup.add_endpoint_info(sender_endpoint.addr());

    let sender_id = sender_endpoint.id();
    let sender_secret = sender_endpoint.secret_key().clone();
    let sender = Transport::spawn(sender_endpoint);
    let receiver = Transport::spawn(receiver_endpoint);
    let topic = TopicId::from(FLEET);
    let mut sender_topic = sender
        .subscribe(topic, vec![])
        .await
        .expect("subscribe sender");
    let mut receiver_topic = receiver
        .subscribe(topic, vec![sender_id])
        .await
        .expect("subscribe receiver");

    timeout(Duration::from_secs(5), sender_topic.joined())
        .await
        .expect("sender joined in time")
        .expect("sender joined");
    timeout(Duration::from_secs(5), receiver_topic.joined())
        .await
        .expect("receiver joined in time")
        .expect("receiver joined");

    let announcement = Announcement {
        fleet_id: FLEET,
        endpoint_id: sender_id,
        node_name: "camera@fleet.local".into(),
        partisan_ip: [192, 168, 1, 10],
        partisan_port: NonZeroU16::new(9_000).unwrap(),
        sequence: 1,
        ttl_ms: 5_000,
        capabilities: BTreeMap::from([("camera".into(), CapabilityValue::Bool(true))]),
        load: Load {
            running: 0,
            capacity: 1,
        },
    };
    let envelope = sign_announcement(&announcement, &sender_secret).expect("sign announcement");
    sender_topic
        .broadcast(envelope)
        .await
        .expect("broadcast announcement");

    let received = timeout(Duration::from_secs(5), receiver_topic.receive())
        .await
        .expect("announcement received in time")
        .expect("receive announcement")
        .expect("topic remains open");
    let authorization = AuthorizationTable::new([(sender_id, announcement.node_name.clone())])
        .expect("valid authorization");
    let mut registry = Registry::new(FLEET, authorization, MemorySequenceStore::default());
    registry
        .receive(&received, 1_000)
        .expect("registry accepts announcement");

    let discovered = registry.active(&sender_id, 1_000).expect("peer discovered");
    assert_eq!(
        discovered.capabilities.get("camera"),
        Some(&CapabilityValue::Bool(true))
    );
    assert_eq!(discovered.partisan_ip, [192, 168, 1, 10]);
    assert_eq!(discovered.partisan_port.get(), 9_000);

    drop(sender_topic);
    drop(receiver_topic);
    sender.shutdown().await.expect("shutdown sender");
    receiver.shutdown().await.expect("shutdown receiver");
}

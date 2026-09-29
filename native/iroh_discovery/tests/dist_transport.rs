use std::{net::SocketAddrV4, time::Duration};

use iroh::{Endpoint, RelayMode, SecretKey, address_lookup::MemoryLookup, endpoint::presets};
use iroh_discovery::{
    dist::{ALPN, CREDIT_WINDOW, Error, Event},
    transport::Transport,
};
use tokio::{sync::mpsc, time::timeout};

async fn endpoint(secret: SecretKey, lookup: MemoryLookup) -> Endpoint {
    Endpoint::builder(presets::Minimal)
        .secret_key(secret)
        .address_lookup(lookup)
        .relay_mode(RelayMode::Disabled)
        .bind_addr(SocketAddrV4::new(std::net::Ipv4Addr::LOCALHOST, 0))
        .expect("bind address")
        .bind()
        .await
        .expect("bind endpoint")
}

async fn pair() -> (
    Transport,
    mpsc::Receiver<Event>,
    Transport,
    mpsc::Receiver<Event>,
) {
    let a_lookup = MemoryLookup::new();
    let b_lookup = MemoryLookup::new();
    let a_endpoint = endpoint(SecretKey::from_bytes(&[31; 32]), a_lookup.clone()).await;
    let b_endpoint = endpoint(SecretKey::from_bytes(&[32; 32]), b_lookup.clone()).await;
    a_lookup.add_endpoint_info(b_endpoint.addr());
    b_lookup.add_endpoint_info(a_endpoint.addr());
    let (a_tx, a_rx) = mpsc::channel(64);
    let (b_tx, b_rx) = mpsc::channel(64);
    let a = Transport::spawn_with_dist(a_endpoint, a_tx);
    let b = Transport::spawn_with_dist(b_endpoint, b_tx);
    a.dist()
        .replace_bindings(vec![(b.endpoint_addr().id, "b@fleet.local".into(), 60_000)]);
    b.dist()
        .replace_bindings(vec![(a.endpoint_addr().id, "a@fleet.local".into(), 60_000)]);
    b.dist().listen("b@fleet.local").expect("listen");
    (a, a_rx, b, b_rx)
}

async fn event(receiver: &mut mpsc::Receiver<Event>) -> Event {
    timeout(Duration::from_secs(5), receiver.recv())
        .await
        .expect("event timeout")
        .expect("event channel")
}

async fn closed(receiver: &mut mpsc::Receiver<Event>) {
    while !matches!(event(receiver).await, Event::Closed { .. }) {}
}

async fn send_fragmented_header(endpoint: &Endpoint, target: iroh::EndpointId, target_node: &str) {
    let conn = endpoint.connect(target, ALPN).await.expect("dial");
    let (mut send, _) = conn.open_bi().await.expect("stream");
    let mut header = Vec::new();
    header.extend_from_slice(b"ERLDIST1");
    for node in ["a@fleet.local", target_node] {
        header.extend_from_slice(&(node.len() as u16).to_be_bytes());
        header.extend_from_slice(node.as_bytes());
    }
    for byte in header {
        send.write_all(&[byte]).await.expect("fragmented header");
    }
    send.finish().expect("finish header");
    let _ = timeout(Duration::from_secs(2), conn.closed()).await;
}

#[tokio::test]
async fn p_two_authenticated_endpoints_are_connected_c_exchange_bytes_and_close_q_order_credit_and_close_hold()
 {
    let (a, mut a_events, b, mut b_events) = pair().await;
    let a_stream = a
        .dist()
        .connect("a@fleet.local".into(), "b@fleet.local".into())
        .await
        .expect("connect");
    assert_eq!(
        event(&mut a_events).await,
        Event::Connected {
            stream_id: a_stream,
            target_node: "b@fleet.local".into()
        }
    );
    let b_stream = match event(&mut b_events).await {
        Event::Incoming {
            stream_id,
            from_node,
            target_node,
        } => {
            assert_eq!(from_node, "a@fleet.local");
            assert_eq!(target_node, "b@fleet.local");
            stream_id
        }
        other => panic!("unexpected event: {other:?}"),
    };

    a.dist()
        .send(a_stream, vec![7; CREDIT_WINDOW])
        .expect("full credit write");
    assert_eq!(
        a.dist().send(a_stream, vec![1]),
        Err(Error::CreditExhausted)
    );
    let mut received = Vec::new();
    while received.len() < CREDIT_WINDOW {
        if let Event::Data { bytes, .. } = event(&mut b_events).await {
            let count = bytes.len();
            received.extend(bytes);
            b.dist().credit(b_stream, count).expect("return credit");
        }
    }
    assert_eq!(received, vec![7; CREDIT_WINDOW]);
    assert_eq!(
        event(&mut a_events).await,
        Event::Credit {
            stream_id: a_stream,
            bytes: CREDIT_WINDOW
        }
    );

    b.dist()
        .send(b_stream, b"one".to_vec())
        .expect("first reverse write");
    b.dist()
        .send(b_stream, b"two".to_vec())
        .expect("second reverse write");
    let mut reverse = Vec::new();
    while reverse.len() < 6 {
        if let Event::Data { bytes, .. } = event(&mut a_events).await {
            reverse.extend(bytes);
        }
    }
    assert_eq!(reverse, b"onetwo");

    a.dist().close(a_stream).expect("close");
    closed(&mut a_events).await;
    closed(&mut b_events).await;
    a.shutdown().await.expect("shutdown a");
    b.shutdown().await.expect("shutdown b");
}

#[tokio::test]
async fn p_headers_are_fragmented_or_mismatched_c_accept_connection_q_valid_header_passes_and_wrong_claims_fail()
 {
    let (a, _a_events, b, mut b_events) = pair().await;
    let lookup = MemoryLookup::new();
    lookup.add_endpoint_info(b.endpoint_addr());
    let attacker = endpoint(SecretKey::from_bytes(&[33; 32]), lookup).await;
    b.dist()
        .replace_bindings(vec![(attacker.id(), "a@fleet.local".into(), 60_000)]);

    send_fragmented_header(&attacker, b.endpoint_addr().id, "wrong@fleet.local").await;
    assert!(
        timeout(Duration::from_millis(200), b_events.recv())
            .await
            .is_err()
    );
    send_fragmented_header(&attacker, b.endpoint_addr().id, "b@fleet.local").await;
    assert!(matches!(event(&mut b_events).await, Event::Incoming { .. }));
    closed(&mut b_events).await;

    b.dist()
        .replace_bindings(vec![(a.endpoint_addr().id, "a@fleet.local".into(), 60_000)]);
    send_fragmented_header(&attacker, b.endpoint_addr().id, "b@fleet.local").await;
    assert!(
        timeout(Duration::from_millis(200), b_events.recv())
            .await
            .is_err()
    );

    drop(attacker);
    a.shutdown().await.expect("shutdown a");
    b.shutdown().await.expect("shutdown b");
}

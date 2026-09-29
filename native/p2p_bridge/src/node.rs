use crate::behaviour::{NodeBehaviour, NodeBehaviourEvent};
use crate::commands::Command;
use crate::events::handle_swarm_event;

use futures::{FutureExt, StreamExt};
use libp2p::{
    Multiaddr, PeerId, StreamProtocol, autonat, connection_limits, dcutr, gossipsub, identify,
    identity::Keypair, kad, mdns, memory_connection_limits, noise, ping, relay, rendezvous,
    request_response, swarm::SwarmEvent, tcp, upnp, yamux,
};
use rustler::{LocalPid, ResourceArc};
use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn get_runtime() -> Result<&'static Runtime, String> {
    if let Some(rt) = RUNTIME.get() {
        return Ok(rt);
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("p2p-bridge-tokio")
        .build()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;
    let _ = RUNTIME.set(rt);
    RUNTIME
        .get()
        .ok_or_else(|| "Tokio runtime initialization race failed".to_string())
}

pub struct NodeHandle {
    pub cmd_tx: mpsc::Sender<Command>,
    pub peer_id: String,
    pub metrics_registry: std::sync::Arc<std::sync::Mutex<prometheus_client::registry::Registry>>,
}

#[rustler::resource_impl]
impl rustler::Resource for NodeHandle {}

impl Drop for NodeHandle {
    fn drop(&mut self) {
        let _ = self.cmd_tx.try_send(Command::Shutdown);
    }
}

pub fn start_node_inner(
    config_map: HashMap<String, rustler::Term>,
) -> Result<ResourceArc<NodeHandle>, String> {
    let config = crate::config::NodeConfig::from_map(&config_map)?;
    let runtime = get_runtime()?;
    let _guard = runtime.enter();

    let keypair = match &config.keypair_bytes {
        Some(bytes) => {
            Keypair::from_protobuf_encoding(bytes).map_err(|e| format!("invalid keypair: {e}"))?
        }
        None => Keypair::generate_ed25519(),
    };

    let local_peer_id = keypair.public().to_peer_id();
    let peer_id_str = local_peer_id.to_base58();

    let limits = connection_limits::ConnectionLimits::default()
        .with_max_pending_incoming(Some(config.max_pending_incoming))
        .with_max_pending_outgoing(Some(config.max_pending_outgoing))
        .with_max_established_incoming(Some(config.max_established_incoming))
        .with_max_established_outgoing(Some(config.max_established_outgoing))
        .with_max_established_per_peer(Some(config.max_established_per_peer))
        .with_max_established(Some(
            config.max_established_incoming + config.max_established_outgoing,
        ));

    let message_id_fn = |message: &gossipsub::Message| {
        let mut hasher = DefaultHasher::new();
        message.data.hash(&mut hasher);
        gossipsub::MessageId::from(hasher.finish().to_string())
    };

    let gossipsub_config = gossipsub::ConfigBuilder::default()
        .heartbeat_interval(Duration::from_millis(
            config.gossipsub_heartbeat_interval_ms,
        ))
        .validation_mode(gossipsub::ValidationMode::Strict)
        .message_id_fn(message_id_fn)
        .mesh_n(config.gossipsub_mesh_n)
        .mesh_n_low(config.gossipsub_mesh_n_low)
        .mesh_n_high(config.gossipsub_mesh_n_high)
        .gossip_lazy(config.gossipsub_gossip_lazy)
        .max_transmit_size(config.gossipsub_max_transmit_size)
        .build()
        .map_err(|e| format!("gossipsub config: {e}"))?;

    let mut gossipsub_behaviour = gossipsub::Behaviour::new(
        gossipsub::MessageAuthenticity::Signed(keypair.clone()),
        gossipsub_config,
    )
    .map_err(|e| format!("gossipsub behaviour: {e}"))?;

    if !config.peer_score_disabled {
        use crate::policy::{gossipsub_default_score as ds, gossipsub_default_thresholds as dt};

        let peer_score_params = match &config.peer_score {
            Some(ps) => gossipsub::PeerScoreParams {
                ip_colocation_factor_weight: ps.ip_colocation_factor_weight,
                ip_colocation_factor_threshold: ps.ip_colocation_factor_threshold,
                behaviour_penalty_weight: ps.behaviour_penalty_weight,
                behaviour_penalty_decay: ps.behaviour_penalty_decay,
                ..Default::default()
            },
            None => gossipsub::PeerScoreParams {
                ip_colocation_factor_weight: ds::IP_COLOCATION_FACTOR_WEIGHT,
                ip_colocation_factor_threshold: ds::IP_COLOCATION_FACTOR_THRESHOLD,
                behaviour_penalty_weight: ds::BEHAVIOUR_PENALTY_WEIGHT,
                behaviour_penalty_decay: ds::BEHAVIOUR_PENALTY_DECAY,
                ..Default::default()
            },
        };

        let thresholds = match &config.thresholds {
            Some(t) => gossipsub::PeerScoreThresholds {
                gossip_threshold: t.gossip_threshold,
                publish_threshold: t.publish_threshold,
                graylist_threshold: t.graylist_threshold,
                accept_px_threshold: t.accept_px_threshold,
                opportunistic_graft_threshold: t.opportunistic_graft_threshold,
            },
            None => gossipsub::PeerScoreThresholds {
                gossip_threshold: dt::GOSSIP,
                publish_threshold: dt::PUBLISH,
                graylist_threshold: dt::GRAYLIST,
                accept_px_threshold: dt::ACCEPT_PX,
                opportunistic_graft_threshold: dt::OPPORTUNISTIC_GRAFT,
            },
        };

        gossipsub_behaviour
            .with_peer_score(peer_score_params, thresholds)
            .map_err(|e| format!("peer scoring: {e}"))?;
    }

    let kademlia = if config.enable_kademlia {
        let store = kad::store::MemoryStore::new(local_peer_id);
        Some(kad::Behaviour::new(local_peer_id, store)).into()
    } else {
        None.into()
    };

    let identify_config = identify::Config::new("/elixir-rpc/0.1.0".into(), keypair.public());
    let identify_behaviour = identify::Behaviour::new(identify_config);

    let mdns_behaviour = if config.enable_mdns {
        Some(
            mdns::tokio::Behaviour::new(mdns::Config::default(), local_peer_id)
                .map_err(|e| format!("mdns: {e}"))?,
        )
        .into()
    } else {
        None.into()
    };

    let rpc_protocol = StreamProtocol::try_from_owned(config.rpc_protocol_name.clone())
        .map_err(|e| format!("invalid protocol name: {e}"))?;

    let rpc_config = request_response::Config::default()
        .with_request_timeout(Duration::from_secs(config.rpc_request_timeout_secs));

    let request_response_behaviour = request_response::cbor::Behaviour::<Vec<u8>, Vec<u8>>::new(
        [(rpc_protocol, request_response::ProtocolSupport::Full)],
        rpc_config,
    );

    let idle_timeout = Duration::from_secs(config.idle_connection_timeout_secs);

    let relay_server_behaviour = if config.enable_relay_server {
        let relay_server_config = relay::Config {
            max_reservations: config.relay_max_reservations as usize,
            max_circuits: config.relay_max_circuits as usize,
            max_circuit_duration: Duration::from_secs(config.relay_max_circuit_duration_secs),
            max_circuit_bytes: config.relay_max_circuit_bytes,
            ..Default::default()
        };
        Some(relay::Behaviour::new(local_peer_id, relay_server_config)).into()
    } else {
        None.into()
    };

    let dcutr_behaviour = if config.enable_relay {
        Some(dcutr::Behaviour::new(local_peer_id)).into()
    } else {
        None.into()
    };

    let autonat_behaviour = if config.enable_autonat {
        Some(autonat::Behaviour::new(
            local_peer_id,
            autonat::Config::default(),
        ))
        .into()
    } else {
        None.into()
    };

    let autonat_server_behaviour: libp2p::swarm::behaviour::toggle::Toggle<
        autonat::v2::server::Behaviour,
    > = if config.enable_autonat_server {
        Some(autonat::v2::server::Behaviour::new(rand::rngs::OsRng)).into()
    } else {
        None.into()
    };

    let upnp_behaviour: libp2p::swarm::behaviour::toggle::Toggle<upnp::tokio::Behaviour> =
        if config.enable_upnp {
            Some(upnp::tokio::Behaviour::default()).into()
        } else {
            None.into()
        };

    let rendezvous_client_behaviour = if config.enable_rendezvous_client {
        Some(rendezvous::client::Behaviour::new(keypair.clone())).into()
    } else {
        None.into()
    };

    let rendezvous_server_behaviour = if config.enable_rendezvous_server {
        Some(rendezvous::server::Behaviour::new(
            rendezvous::server::Config::default(),
        ))
        .into()
    } else {
        None.into()
    };

    let memory_limits =
        memory_connection_limits::Behaviour::with_max_percentage(config.memory_max_percentage);

    let mut metrics_registry = prometheus_client::registry::Registry::default();

    let mut swarm = libp2p::SwarmBuilder::with_existing_identity(keypair)
        .with_tokio()
        .with_tcp(
            tcp::Config::default().nodelay(true),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|e| format!("tcp transport: {e}"))?
        .with_quic()
        .with_dns()
        .map_err(|e| format!("dns: {e}"))?
        .with_relay_client(noise::Config::new, yamux::Config::default)
        .map_err(|e| format!("relay client: {e}"))?
        .with_bandwidth_metrics(&mut metrics_registry)
        .with_behaviour(|_key, relay_client| {
            Ok(NodeBehaviour {
                connection_limits: connection_limits::Behaviour::new(limits),
                memory_limits,
                identify: identify_behaviour,
                ping: ping::Behaviour::default(),
                gossipsub: gossipsub_behaviour,
                request_response: request_response_behaviour,
                kademlia,
                mdns: mdns_behaviour,
                rendezvous_client: rendezvous_client_behaviour,
                rendezvous_server: rendezvous_server_behaviour,
                relay_client,
                relay_server: relay_server_behaviour,
                dcutr: dcutr_behaviour,
                autonat: autonat_behaviour,
                autonat_server: autonat_server_behaviour,
                upnp: upnp_behaviour,
            })
        })
        .map_err(|e| format!("behaviour: {e}"))?
        .with_swarm_config(|cfg| cfg.with_idle_connection_timeout(idle_timeout))
        .build();

    for topic_str in &config.gossipsub_topics {
        let topic = gossipsub::IdentTopic::new(topic_str);
        swarm
            .behaviour_mut()
            .gossipsub
            .subscribe(&topic)
            .map_err(|e| format!("subscribe {topic_str}: {e}"))?;
    }

    for addr_str in &config.listen_addrs {
        let addr: Multiaddr = addr_str
            .parse()
            .map_err(|e| format!("invalid listen addr {addr_str}: {e}"))?;
        swarm.listen_on(addr).map_err(|e| format!("listen: {e}"))?;
    }

    let (cmd_tx, cmd_rx) = mpsc::channel(512);
    let handle_tx = cmd_tx.clone();

    let mdns_auto_dial = config.mdns_auto_dial;
    runtime.spawn(async move {
        let result = std::panic::AssertUnwindSafe(swarm_loop(swarm, cmd_rx, mdns_auto_dial))
            .catch_unwind()
            .await;
        if let Err(e) = result {
            tracing::error!("swarm loop panicked: {e:?}");
        }
    });

    Ok(ResourceArc::new(NodeHandle {
        cmd_tx: handle_tx,
        peer_id: peer_id_str,
        metrics_registry: std::sync::Arc::new(std::sync::Mutex::new(metrics_registry)),
    }))
}

async fn swarm_loop(
    mut swarm: libp2p::Swarm<NodeBehaviour>,
    mut cmd_rx: mpsc::Receiver<Command>,
    mdns_auto_dial: bool,
) {
    let mut event_handler: Option<LocalPid> = None;

    let mut pending_responses: HashMap<
        String,
        (request_response::ResponseChannel<Vec<u8>>, Instant),
    > = HashMap::new();
    let mut channel_counter: u64 = 0;
    let response_ttl = Duration::from_secs(60);
    let mut eviction_interval = tokio::time::interval(Duration::from_secs(15));

    loop {
        tokio::select! {
            _ = eviction_interval.tick() => {
                let now = Instant::now();
                pending_responses.retain(|id, (_, created)| {
                    let keep = now.duration_since(*created) < response_ttl;
                    if !keep { tracing::debug!(%id, "evicting stale pending response"); }
                    keep
                });
            }

            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(Command::RegisterEventHandler { pid }) => {
                        event_handler = Some(pid);
                    }
                    Some(Command::Dial { addr }) => {
                        if let Err(e) = swarm.dial(addr.clone()) {
                            tracing::warn!(%addr, %e, "dial failed");
                        }
                    }
                    Some(Command::Publish { topic, data }) => {
                        let topic = gossipsub::IdentTopic::new(topic);
                        if let Err(e) = swarm.behaviour_mut().gossipsub.publish(topic, data) {
                            tracing::warn!(%e, "publish failed");
                        }
                    }
                    Some(Command::Subscribe { topic }) => {
                        let topic = gossipsub::IdentTopic::new(topic);
                        if let Err(e) = swarm.behaviour_mut().gossipsub.subscribe(&topic) {
                            tracing::warn!(%e, "subscribe failed");
                        }
                    }
                    Some(Command::Unsubscribe { topic }) => {
                        let topic = gossipsub::IdentTopic::new(topic);
                        let _was_subscribed = swarm.behaviour_mut().gossipsub.unsubscribe(&topic);
                    }
                    Some(Command::GossipsubMeshPeers { topic, reply }) => {
                        let topic_hash = gossipsub::IdentTopic::new(topic).hash();
                        let peers: Vec<PeerId> = swarm.behaviour()
                            .gossipsub.mesh_peers(&topic_hash)
                            .cloned().collect();
                        let _ = reply.send(peers);
                    }
                    Some(Command::GossipsubAllPeers { reply }) => {
                        let peers: Vec<PeerId> = swarm.behaviour()
                            .gossipsub.all_peers()
                            .map(|(p, _)| *p).collect();
                        let _ = reply.send(peers);
                    }
                    Some(Command::GossipsubPeerScore { peer_id, reply }) => {
                        let score = swarm.behaviour().gossipsub.peer_score(&peer_id);
                        let _ = reply.send(score);
                    }
                    Some(Command::ConnectedPeers { reply }) => {
                        let peers: Vec<PeerId> = swarm.connected_peers().cloned().collect();
                        let _ = reply.send(peers);
                    }
                    Some(Command::ListeningAddrs { reply }) => {
                        let addrs: Vec<Multiaddr> = swarm.listeners().cloned().collect();
                        let _ = reply.send(addrs);
                    }
                    Some(Command::BandwidthStats { reply }) => {
                        let _ = reply.send((0, 0));
                    }
                    Some(Command::DhtPut { key, value }) => {
                        if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            let record = kad::Record::new(key, value);
                            if let Err(e) = kad.put_record(record, kad::Quorum::One) {
                                tracing::warn!(%e, "dht put failed");
                            }
                        } else {
                            tracing::warn!("DHT not enabled — ignoring dht_put");
                        }
                    }
                    Some(Command::DhtGet { key }) => {
                        if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            kad.get_record(key.into());
                        } else {
                            tracing::warn!("DHT not enabled — ignoring dht_get");
                        }
                    }
                    Some(Command::DhtFindPeer { peer_id }) => {
                        if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            kad.get_closest_peers(peer_id);
                        } else {
                            tracing::warn!("DHT not enabled — ignoring dht_find_peer");
                        }
                    }
                    Some(Command::DhtProvide { key }) => {
                        if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            if let Err(e) = kad.start_providing(key.into()) {
                                tracing::warn!(%e, "dht provide failed");
                            }
                        } else {
                            tracing::warn!("DHT not enabled — ignoring dht_provide");
                        }
                    }
                    Some(Command::DhtFindProviders { key }) => {
                        if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            kad.get_providers(key.into());
                        } else {
                            tracing::warn!("DHT not enabled — ignoring dht_find_providers");
                        }
                    }
                    Some(Command::DhtBootstrap) => {
                        if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            if let Err(e) = kad.bootstrap() {
                                tracing::warn!(%e, "dht bootstrap failed");
                            }
                        } else {
                            tracing::warn!("DHT not enabled — ignoring dht_bootstrap");
                        }
                    }
                    Some(Command::DhtExportRoutingTable { reply }) => {
                        let result = if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            let mut entries = Vec::new();
                            for bucket in kad.kbuckets() {
                                for entry_view in bucket.iter() {
                                    let peer_id_bytes = entry_view.node.key.preimage().to_bytes();
                                    let addresses = entry_view.node.value.iter().map(|a| a.to_vec()).collect();
                                    entries.push(crate::dht_state::RoutingEntry { peer_id: peer_id_bytes, addresses });
                                }
                            }
                            Ok(entries)
                        } else {
                            Err(())
                        };
                        let _ = reply.send(result);
                    }
                    Some(Command::DhtImportRoutingTable { entries, reply }) => {
                        let result = if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                            let mut count = 0usize;
                            for entry in entries {
                                let peer_id = match PeerId::from_bytes(&entry.peer_id) {
                                    Ok(p) => p,
                                    Err(e) => { tracing::warn!(%e, "skipping invalid peer_id during import"); continue; }
                                };
                                for addr_bytes in entry.addresses {
                                    let addr = match Multiaddr::try_from(addr_bytes) {
                                        Ok(a) => a,
                                        Err(e) => { tracing::warn!(%e, "skipping invalid multiaddr during import"); continue; }
                                    };
                                    kad.add_address(&peer_id, addr);
                                    count += 1;
                                }
                            }
                            Ok(count)
                        } else {
                            Err(())
                        };
                        let _ = reply.send(result);
                    }
                    Some(Command::RpcSendRequest { peer_id, data, reply }) => {
                        let req_id = swarm.behaviour_mut().request_response.send_request(&peer_id, data);
                        let _ = reply.send(format!("{req_id:?}"));
                    }
                    Some(Command::RpcSendResponse { channel_id, data }) => {
                        match pending_responses.remove(&channel_id) {
                            Some((channel, _created)) => {
                                if let Err(resp) = swarm.behaviour_mut().request_response.send_response(channel, data) {
                                    tracing::warn!(%channel_id, resp_len = resp.len(), "send_response failed: channel closed");
                                }
                            }
                            None => {
                                tracing::warn!(%channel_id, "send_response: unknown channel ID (expired or already used)");
                            }
                        }
                    }
                    Some(Command::ListenViaRelay { relay_addr }) => {
                        if let Err(e) = swarm.listen_on(relay_addr.clone()) {
                            tracing::warn!(%relay_addr, %e, "listen via relay failed");
                        }
                    }
                    Some(Command::RendezvousRegister { namespace, ttl, rendezvous_peer }) => {
                        if let Some(rv) = swarm.behaviour_mut().rendezvous_client.as_mut() {
                            let ns = match rendezvous::Namespace::new(namespace.clone()) {
                                Ok(ns) => ns,
                                Err(e) => { tracing::warn!(%namespace, %e, "invalid rendezvous namespace"); continue; }
                            };
                            if let Err(e) = rv.register(ns, rendezvous_peer, Some(ttl)) {
                                tracing::warn!(%namespace, %e, "rendezvous register failed");
                            }
                        } else {
                            tracing::warn!("rendezvous client not enabled");
                        }
                    }
                    Some(Command::RendezvousDiscover { namespace, rendezvous_peer }) => {
                        if let Some(rv) = swarm.behaviour_mut().rendezvous_client.as_mut() {
                            let ns = rendezvous::Namespace::new(namespace.clone()).ok();
                            rv.discover(ns, None, None, rendezvous_peer);
                        } else {
                            tracing::warn!("rendezvous client not enabled");
                        }
                    }
                    Some(Command::RendezvousUnregister { namespace, rendezvous_peer }) => {
                        if let Some(rv) = swarm.behaviour_mut().rendezvous_client.as_mut() {
                            let ns = match rendezvous::Namespace::new(namespace.clone()) {
                                Ok(ns) => ns,
                                Err(e) => { tracing::warn!(%namespace, %e, "invalid rendezvous namespace"); continue; }
                            };
                            rv.unregister(ns, rendezvous_peer);
                        } else {
                            tracing::warn!("rendezvous client not enabled");
                        }
                    }
                    Some(Command::Shutdown) | None => break,
                }
            }

            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::Behaviour(NodeBehaviourEvent::RequestResponse(
                        request_response::Event::Message {
                            peer,
                            message: request_response::Message::Request { request_id, request, channel },
                            ..
                        },
                    )) => {
                        if pending_responses.len() >= crate::policy::MAX_PENDING_RESPONSES {
                            tracing::warn!(
                                peer = %peer,
                                cap = crate::policy::MAX_PENDING_RESPONSES,
                                "request-response pending cap reached — dropping inbound request"
                            );
                            continue;
                        }
                        channel_counter += 1;
                        let channel_id = format!("ch-{channel_counter}");
                        pending_responses.insert(channel_id.clone(), (channel, Instant::now()));

                        if let Some(ref pid) = event_handler {
                            crate::events::send_inbound_request(pid, &peer, &format!("{request_id:?}"), &channel_id, &request);
                        }
                    }
                    SwarmEvent::Behaviour(NodeBehaviourEvent::RequestResponse(
                        request_response::Event::Message {
                            peer,
                            message: request_response::Message::Response { request_id, response },
                            ..
                        },
                    )) => {
                        if let Some(ref pid) = event_handler {
                            crate::events::send_outbound_response(pid, &peer, &format!("{request_id:?}"), &response);
                        }
                    }
                    SwarmEvent::Behaviour(NodeBehaviourEvent::Mdns(
                        libp2p::mdns::Event::Discovered(peers),
                    )) => {
                        let peer_pairs: Vec<(PeerId, Multiaddr)> = peers.into_iter().collect();
                        for (peer_id, addr) in &peer_pairs {
                            if let Some(kad) = swarm.behaviour_mut().kademlia.as_mut() {
                                kad.add_address(peer_id, addr.clone());
                            }
                            if mdns_auto_dial
                                && !swarm.is_connected(peer_id)
                                && let Err(e) = swarm.dial(*peer_id)
                            {
                                tracing::debug!(%peer_id, %e, "mdns auto-dial skipped");
                            }
                        }
                        if let Some(ref pid) = event_handler {
                            crate::events::send_peers_discovered(pid, &peer_pairs);
                        }
                    }
                    SwarmEvent::Behaviour(NodeBehaviourEvent::Mdns(libp2p::mdns::Event::Expired(_))) => {}
                    other => {
                        if let Some(ref pid) = event_handler {
                            handle_swarm_event(other, pid);
                        }
                    }
                }
            }
        }
    }

    tracing::info!("swarm loop exited");
}

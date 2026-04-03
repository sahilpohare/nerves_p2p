use crate::behaviour::P2PBehaviourEvent;
use crate::protocol::{Event, PartisanCompatiblePeerID, PortProtocol};
use crate::tui::{LogLevel, StateUpdate};
use libp2p::{dcutr, identify, kad, mdns, ping, relay, PeerId};
use std::collections::{HashMap, HashSet};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

/// Emit a state update to the TUI channel if we are in standalone mode.
macro_rules! tui {
    ($tx:expr, $update:expr) => {
        if let Some(tx) = $tx {
            let _ = tx.send($update);
        }
    };
}

/// Handle libp2p swarm events.
///
/// In Port mode, `tx_state` is `None` and events are sent to Elixir via `port_protocol`.
/// In standalone mode, `tx_state` is `Some` and events are sent to the TUI.
pub async fn handle_swarm_event(
    event: libp2p::swarm::SwarmEvent<P2PBehaviourEvent>,
    discovered_peers: &mut HashSet<PeerId>,
    port_protocol: &mut PortProtocol,
    swarm: &mut libp2p::Swarm<crate::behaviour::P2PBehaviour>,
    pending_queries: &mut HashMap<kad::QueryId, Option<String>>,
    tx_state: Option<&mpsc::UnboundedSender<StateUpdate>>,
) {
    use libp2p::swarm::SwarmEvent;

    match event {
        SwarmEvent::NewListenAddr { address, .. } => {
            info!("Listening on {}", address);
            let addr = address.to_string();
            tui!(tx_state, StateUpdate::ListenAddr(addr.clone()));
            let _ = port_protocol.send_event(Event::ListeningOn { multiaddr: addr });
        }

        SwarmEvent::Behaviour(P2PBehaviourEvent::Mdns(mdns::Event::Discovered(peers))) => {
            for (peer_id, addr) in peers {
                if discovered_peers.insert(peer_id) {
                    info!("Discovered peer via mDNS: {} at {}", peer_id, addr);
                    swarm.behaviour_mut().kad.add_address(&peer_id, addr.clone());

                    let (pid, ma) = (peer_id.to_string(), addr.to_string());
                    tui!(tx_state, StateUpdate::PeerDiscovered {
                        peer_id: pid.clone(),
                        multiaddr: ma.clone(),
                        protocol: "mdns".to_string(),
                    });
                    let _ = port_protocol.send_event(Event::PeerDiscovered {
                        peer_id: pid,
                        multiaddr: ma,
                        protocol: "mdns".to_string(),
                    });
                }
            }
        }

        SwarmEvent::Behaviour(P2PBehaviourEvent::Mdns(mdns::Event::Expired(peers))) => {
            for (peer_id, _) in peers {
                discovered_peers.remove(&peer_id);
                debug!("mDNS peer expired: {}", peer_id);
            }
        }

        SwarmEvent::Behaviour(P2PBehaviourEvent::Identify(identify::Event::Received {
            peer_id,
            info,
            connection_id: _,
        })) => {
            debug!("Identified peer {}: {:?}", peer_id, info);
            for addr in &info.listen_addrs {
                swarm.behaviour_mut().kad.add_address(&peer_id, addr.clone());
            }
            for addr in info.listen_addrs {
                let (pid, ma) = (peer_id.to_string(), addr.to_string());
                tui!(tx_state, StateUpdate::PeerDiscovered {
                    peer_id: pid.clone(),
                    multiaddr: ma.clone(),
                    protocol: "identify".to_string(),
                });
                let _ = port_protocol.send_event(Event::PeerDiscovered {
                    peer_id: pid,
                    multiaddr: ma,
                    protocol: "identify".to_string(),
                });
            }
        }

        SwarmEvent::Behaviour(P2PBehaviourEvent::Dcutr(dcutr::Event {
            remote_peer_id,
            result,
        })) => {
            match result {
                Ok(_) => {
                    info!("DCUtR hole punching successful with {}", remote_peer_id);
                    let status = format!("dcutr_success:{}", remote_peer_id);
                    tui!(tx_state, StateUpdate::NatStatus(status.clone()));
                    let _ = port_protocol.send_event(Event::NatStatus { status });
                }
                Err(e) => {
                    warn!("DCUtR hole punching failed with {}: {:?}", remote_peer_id, e);
                    tui!(tx_state, StateUpdate::Log {
                        level: LogLevel::Warn,
                        message: format!("DCUtR failed with {}: {:?}", remote_peer_id, e),
                    });
                }
            }
        }

        SwarmEvent::Behaviour(P2PBehaviourEvent::RelayClient(
            relay::client::Event::ReservationReqAccepted { relay_peer_id, .. },
        )) => {
            info!("Relay reservation accepted by {}", relay_peer_id);
            let status = format!("relay_available:{}", relay_peer_id);
            tui!(tx_state, StateUpdate::NatStatus(status.clone()));
            let _ = port_protocol.send_event(Event::NatStatus { status });
        }

        SwarmEvent::ConnectionEstablished {
            peer_id, endpoint, ..
        } => {
            info!("Connection established with {}: {:?}", peer_id, endpoint);
            let (pid, ma) = (peer_id.to_string(), endpoint.get_remote_address().to_string());
            tui!(tx_state, StateUpdate::PeerConnected {
                peer_id: pid.clone(),
                multiaddr: ma.clone(),
            });
            let _ = port_protocol.send_event(Event::ConnectionEstablished {
                peer_id: pid,
                multiaddr: ma,
            });
        }

        SwarmEvent::ConnectionClosed { peer_id, cause, .. } => {
            warn!("Connection closed with {}: {:?}", peer_id, cause);
            let pid = peer_id.to_string();
            tui!(tx_state, StateUpdate::PeerDisconnected(pid.clone()));
            let _ = port_protocol.send_event(Event::ConnectionClosed { peer_id: pid });
        }

        SwarmEvent::IncomingConnection { send_back_addr, .. } => {
            debug!("Incoming connection from {}", send_back_addr);
        }

        SwarmEvent::OutgoingConnectionError {
            peer_id: Some(peer_id),
            error,
            ..
        } => {
            warn!("Outgoing connection error to {}: {:?}", peer_id, error);
            tui!(tx_state, StateUpdate::Log {
                level: LogLevel::Warn,
                message: format!("Connection error to {}: {:?}", peer_id, error),
            });
        }

        SwarmEvent::Behaviour(P2PBehaviourEvent::Ping(ping::Event {
            peer,
            result: Err(e),
            ..
        })) => {
            warn!("Ping failed for {}: {:?}", peer, e);
        }

        SwarmEvent::Behaviour(P2PBehaviourEvent::Kad(kad_event)) => {
            handle_kad_event(kad_event, port_protocol, pending_queries, tx_state);
        }

        _ => {}
    }
}

/// Handle Kademlia DHT events
fn handle_kad_event(
    event: kad::Event,
    port_protocol: &mut PortProtocol,
    pending_queries: &mut HashMap<kad::QueryId, Option<String>>,
    tx_state: Option<&mpsc::UnboundedSender<StateUpdate>>,
) {
    match event {
        kad::Event::RoutingUpdated {
            peer,
            is_new_peer,
            addresses,
            ..
        } => {
            if is_new_peer {
                info!("New peer added to routing table: {} ({:?})", peer, addresses);
                for addr in addresses.iter() {
                    let (pid, ma) = (peer.to_string(), addr.to_string());
                    tui!(tx_state, StateUpdate::PeerDiscovered {
                        peer_id: pid.clone(),
                        multiaddr: ma.clone(),
                        protocol: "kad".to_string(),
                    });
                    let _ = port_protocol.send_event(Event::PeerDiscovered {
                        peer_id: pid,
                        multiaddr: ma,
                        protocol: "kad".to_string(),
                    });
                }
            }
        }

        kad::Event::OutboundQueryProgressed {
            id,
            result,
            stats,
            step,
        } => {
            debug!(
                "Kademlia query {:?} progressed: step={:?}, stats={:?}",
                id, step, stats
            );

            match result {
                kad::QueryResult::GetClosestPeers(Ok(kad::GetClosestPeersOk { key, peers })) => {
                    info!(
                        "Found {} closest peers for key {:?}",
                        peers.len(),
                        hex::encode(&key)
                    );
                    let query_ref = pending_queries.remove(&id).flatten();
                    let peer_infos: Vec<PartisanCompatiblePeerID> = peers
                        .into_iter()
                        .map(PartisanCompatiblePeerID::from_peer_info)
                        .collect();

                    tui!(tx_state, StateUpdate::Log {
                        level: LogLevel::Info,
                        message: format!(
                            "DHT query result: {} peers{}",
                            peer_infos.len(),
                            query_ref.as_deref().map(|r| format!(" (ref={})", r)).unwrap_or_default(),
                        ),
                    });
                    let _ = port_protocol.send_event(Event::PeersFound {
                        query_ref,
                        peers: peer_infos,
                    });
                }

                kad::QueryResult::GetClosestPeers(Err(e)) => {
                    warn!("Failed to get closest peers: {:?}", e);
                }

                kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FoundRecord(record))) => {
                    info!(
                        "Found DHT record: key={:?}, value_len={}",
                        hex::encode(&record.record.key),
                        record.record.value.len()
                    );
                }

                kad::QueryResult::GetRecord(Err(e)) => {
                    debug!("Get record query failed: {:?}", e);
                }

                kad::QueryResult::PutRecord(Ok(kad::PutRecordOk { key })) => {
                    info!("Successfully put DHT record: {:?}", hex::encode(&key));
                }

                kad::QueryResult::PutRecord(Err(e)) => {
                    warn!("Failed to put DHT record: {:?}", e);
                }

                kad::QueryResult::Bootstrap(Ok(kad::BootstrapOk {
                    peer,
                    num_remaining,
                })) => {
                    info!(
                        "Bootstrap progressed with peer {:?}, {} remaining",
                        peer, num_remaining
                    );
                }

                kad::QueryResult::Bootstrap(Err(e)) => {
                    warn!("Bootstrap query failed: {:?}", e);
                }

                _ => {
                    debug!("Unhandled Kademlia query result: {:?}", result);
                }
            }
        }

        kad::Event::InboundRequest { request } => {
            debug!("Received inbound Kademlia request: {:?}", request);
        }

        _ => {
            debug!("Unhandled Kademlia event: {:?}", event);
        }
    }
}

use crate::behaviour::P2PBehaviour;
use crate::protocol::{Command, Event, PortProtocol};
use anyhow::Result;
use libp2p::{kad, Multiaddr, Swarm};
use std::collections::HashMap;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tracing::{debug, info};

/// TTL for capability records in the DHT (10 minutes)
const CAPABILITY_TTL: Duration = Duration::from_secs(600);

/// Handle commands from Elixir.
///
/// `pending_queries` maps in-flight `kad::QueryId`s to the caller-supplied `query_ref`
/// so that `PeersFound` events can be correlated back to the originating `QueryPeers` command.
pub async fn handle_command(
    line: &str,
    swarm: &mut Swarm<P2PBehaviour>,
    port_protocol: &mut PortProtocol,
    pending_queries: &mut HashMap<kad::QueryId, Option<String>>,
) -> Result<()> {
    let command: Command = serde_json::from_str(line)?;
    debug!("Received command: {:?}", command);

    match command {
        Command::GetPeerId => {
            let peer_id = *swarm.local_peer_id();
            port_protocol.send_event(Event::PeerId {
                peer_id: peer_id.to_string(),
            })?;
        }

        Command::GetListenAddrs => {
            let addrs: Vec<String> = swarm.listeners().map(|addr| addr.to_string()).collect();
            port_protocol.send_event(Event::ListenAddrs { addrs })?;
        }

        Command::Dial { multiaddr } => {
            let addr: Multiaddr = multiaddr.parse()?;
            swarm.dial(addr)?;
            port_protocol.send_event(Event::DialingPeer {
                multiaddr: multiaddr.clone(),
            })?;
        }

        Command::GetConnectedPeers => {
            let peers: Vec<String> = swarm
                .connected_peers()
                .map(|peer_id| peer_id.to_string())
                .collect();
            port_protocol.send_event(Event::ConnectedPeers { peers })?;
        }

        Command::Ping => {
            port_protocol.send_event(Event::Pong)?;
        }

        Command::Advertise { capabilities } => {
            let peer_id = *swarm.local_peer_id();

            let capabilities_json = serde_json::to_string(&capabilities)?;
            let record_key = format!("capabilities:{}", peer_id);

            let expires = SystemTime::now()
                .checked_add(CAPABILITY_TTL)
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| std::time::Instant::now() + Duration::from_secs(d.as_secs()));

            let record = kad::Record {
                key: kad::RecordKey::new(&record_key.as_bytes()),
                value: capabilities_json.into_bytes(),
                publisher: Some(peer_id),
                expires,
            };

            swarm
                .behaviour_mut()
                .kad
                .put_record(record, kad::Quorum::One)?;

            info!("Advertising capabilities to DHT: {:?}", capabilities);
            port_protocol.send_event(Event::Advertising {
                capabilities: capabilities.clone(),
            })?;
        }

        Command::QueryPeers {
            capabilities,
            limit,
            query_ref,
        } => {
            info!(
                "Querying DHT for peers with capabilities: {:?} (limit: {:?})",
                capabilities, limit
            );

            if capabilities.is_empty() {
                // No filter: search for any capability key
                let key_bytes = b"capabilities:any".to_vec();
                let qid = swarm.behaviour_mut().kad.get_closest_peers(key_bytes);
                pending_queries.insert(qid, query_ref);
            } else {
                // Issue one DHT query per capability so none are silently dropped.
                // The last query's ID is stored; earlier results arrive with None query_ref
                // to signal they are partial. Elixir should merge results by query_ref.
                for (i, (cap_name, _)) in capabilities.iter().enumerate() {
                    let key_bytes = format!("capabilities:{}", cap_name).into_bytes();
                    let qid = swarm.behaviour_mut().kad.get_closest_peers(key_bytes);
                    // Only the last query echoes back the caller's query_ref so the
                    // Elixir side knows when to consider the full result set complete.
                    let ref_for_this_query = if i == capabilities.len() - 1 {
                        query_ref.clone()
                    } else {
                        None
                    };
                    pending_queries.insert(qid, ref_for_this_query);
                }
                debug!(
                    "Initiated {} DHT queries for capabilities: {:?}",
                    capabilities.len(),
                    capabilities
                );
            }
        }
    }

    Ok(())
}

mod behaviour;
mod command_handler;
mod config;
mod event_handler;
mod protocol;
mod tui;

use anyhow::Result;
use behaviour::P2PBehaviour;
use clap::Parser;
use command_handler::handle_command;
use config::Config;
use event_handler::handle_swarm_event;
use futures::StreamExt;
use is_terminal::IsTerminal;
use libp2p::{kad, noise, tcp, yamux, PeerId, SwarmBuilder};
use protocol::PortProtocol;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::interval;
use tracing::{error, info};
use tui::{FoundPeer, StateUpdate, TuiCommand};

const MAX_QUERY_RESULTS: usize = 5;

/// Tracks a two-phase DHT query: first find closest peers, then fetch each record.
struct PendingTuiQuery {
    key: String,
    /// Per-peer record fetch QueryId -> peer_id string
    fetch_ids: HashMap<kad::QueryId, String>,
    /// Accumulated results so far
    results: Vec<FoundPeer>,
}

/// Get the path to the peer ID file
fn get_peer_id_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".peer_id")
}

/// Load an existing keypair from ~/.peer_id or generate a new one.
/// When `transient` is true, always generate a fresh keypair without touching disk.
fn load_or_generate_keypair(transient: bool) -> Result<libp2p::identity::Keypair> {
    if transient {
        let keypair = libp2p::identity::Keypair::generate_ed25519();
        info!("Generated transient keypair (not persisted)");
        return Ok(keypair);
    }

    let peer_id_path = get_peer_id_path();

    if peer_id_path.exists() {
        match fs::read(&peer_id_path) {
            Ok(bytes) => {
                match libp2p::identity::Keypair::from_protobuf_encoding(&bytes) {
                    Ok(keypair) => {
                        info!("Loaded existing keypair from {:?}", peer_id_path);
                        return Ok(keypair);
                    }
                    Err(e) => {
                        error!("Failed to decode keypair from {:?}: {}", peer_id_path, e);
                        info!("Generating new keypair...");
                    }
                }
            }
            Err(e) => {
                error!("Failed to read keypair from {:?}: {}", peer_id_path, e);
                info!("Generating new keypair...");
            }
        }
    }

    let keypair = libp2p::identity::Keypair::generate_ed25519();

    let encoded = keypair
        .to_protobuf_encoding()
        .map_err(|e| anyhow::anyhow!("Failed to encode keypair: {}", e))?;

    if let Err(e) = fs::write(&peer_id_path, &encoded) {
        error!("Failed to save keypair to {:?}: {}", peer_id_path, e);
    } else {
        info!("Saved new keypair to {:?}", peer_id_path);
    }

    Ok(keypair)
}

#[tokio::main]
async fn main() -> Result<()> {
    let standalone = std::io::stdin().is_terminal();

    // In port mode: log to stderr without ANSI (captured by Elixir).
    // In standalone mode: suppress tracing entirely — the TUI event log panel shows events.
    if !standalone {
        tracing_subscriber::fmt()
            .with_writer(std::io::stderr)
            .with_env_filter("p2p_bridge=debug,libp2p=info")
            .with_ansi(false)
            .init();
    }

    info!("P2P Bridge starting...");

    let config = Config::parse();

    let local_key = load_or_generate_keypair(config.transient)?;
    let local_peer_id = PeerId::from(local_key.public());
    info!("Local PeerID: {}", local_peer_id);

    let mut swarm = SwarmBuilder::with_existing_identity(local_key)
        .with_tokio()
        .with_tcp(tcp::Config::default(), noise::Config::new, yamux::Config::default)?
        .with_quic()
        .with_relay_client(noise::Config::new, yamux::Config::default)?
        .with_behaviour(|keypair, relay_client| {
            P2PBehaviour::new(keypair, relay_client).expect("Failed to create P2PBehaviour")
        })?
        .with_swarm_config(|c: libp2p::swarm::Config| {
            c.with_idle_connection_timeout(Duration::from_secs(60))
        })
        .build();

    if config.listen_addrs.is_empty() {
        swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse()?)?;
        swarm.listen_on("/ip6/::/tcp/0".parse()?)?;
    } else {
        for addr in &config.listen_addrs {
            swarm.listen_on(addr.clone())?;
        }
    }

    swarm.behaviour_mut().kad.set_mode(Some(libp2p::kad::Mode::Server));

    let mut port_protocol = PortProtocol::new();
    let mut discovered_peers: HashSet<PeerId> = HashSet::new();
    let mut pending_queries: HashMap<libp2p::kad::QueryId, Option<String>> = HashMap::new();

    if standalone {
        run_standalone(
            swarm,
            &mut port_protocol,
            &mut discovered_peers,
            &mut pending_queries,
            local_peer_id,
        )
        .await
    } else {
        run_port_mode(
            swarm,
            &mut port_protocol,
            &mut discovered_peers,
            &mut pending_queries,
        )
        .await
    }
}

/// Port mode: read JSON commands from stdin, send JSON events to stdout.
async fn run_port_mode(
    mut swarm: libp2p::Swarm<P2PBehaviour>,
    port_protocol: &mut PortProtocol,
    discovered_peers: &mut HashSet<PeerId>,
    pending_queries: &mut HashMap<libp2p::kad::QueryId, Option<String>>,
) -> Result<()> {
    info!("P2P Bridge ready (port mode), listening for commands...");

    let stdin = tokio::io::stdin();
    let reader = tokio::io::BufReader::new(stdin);
    let mut lines = tokio::io::AsyncBufReadExt::lines(reader);

    loop {
        tokio::select! {
            line_result = lines.next_line() => {
                match line_result {
                    Ok(Some(line)) if !line.trim().is_empty() => {
                        if let Err(e) = handle_command(&line, &mut swarm, port_protocol, pending_queries).await {
                            error!("Failed to handle command: {}", e);
                        }
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => {
                        info!("Stdin closed, shutting down");
                        break;
                    }
                    Err(e) => {
                        error!("Failed to read stdin: {}", e);
                        break;
                    }
                }
            }
            event = swarm.select_next_some() => {
                handle_swarm_event(
                    event,
                    discovered_peers,
                    port_protocol,
                    &mut swarm,
                    pending_queries,
                    None,
                )
                .await;
            }
        }
    }

    Ok(())
}

/// Standalone mode: run the ratatui TUI and accept keyboard commands.
async fn run_standalone(
    mut swarm: libp2p::Swarm<P2PBehaviour>,
    port_protocol: &mut PortProtocol,
    discovered_peers: &mut HashSet<PeerId>,
    pending_queries: &mut HashMap<libp2p::kad::QueryId, Option<String>>,
    local_peer_id: PeerId,
) -> Result<()> {
    let (tx_state, rx_state) = mpsc::unbounded_channel::<StateUpdate>();
    let (tx_cmd, mut rx_cmd) = mpsc::channel::<TuiCommand>(32);

    // Phase 1: closest-peers QueryId -> key string
    let mut phase1: HashMap<kad::QueryId, String> = HashMap::new();
    // Phase 2: record-fetch QueryId -> PendingTuiQuery (shared via key string lookup)
    //   fetch_qid -> key string, then look up pending by key
    let mut phase2_qid_to_key: HashMap<kad::QueryId, String> = HashMap::new();
    let mut pending_tui: HashMap<String, PendingTuiQuery> = HashMap::new();

    // Keys we are advertising, re-put periodically so they expire when we die
    let mut my_ads: Vec<String> = Vec::new();
    // Re-advertise interval — records have a 2-min TTL so refresh at 90s
    let mut readvertise_tick = interval(Duration::from_secs(90));
    readvertise_tick.tick().await; // consume the immediate first tick

    const AD_TTL: Duration = Duration::from_secs(120);

    let _ = tx_state.send(StateUpdate::PeerId(local_peer_id.to_string()));

    let tui_handle = tokio::spawn(tui::run_tui(rx_state, tx_cmd));

    loop {
        tokio::select! {
            Some(cmd) = rx_cmd.recv() => {
                match cmd {
                    TuiCommand::Dial(addr) => {
                        match addr.parse::<libp2p::Multiaddr>() {
                            Ok(ma) => { let _ = swarm.dial(ma); }
                            Err(e) => {
                                let _ = tx_state.send(StateUpdate::Log {
                                    level: tui::LogLevel::Error,
                                    message: format!("Invalid multiaddr '{}': {}", addr, e),
                                });
                            }
                        }
                    }
                    TuiCommand::Advertise(key) => {
                        let addrs: Vec<String> = swarm.listeners().map(|a| a.to_string()).collect();
                        // Store under "<key>/<peer_id>" so each peer has its own slot
                        let slot = format!("{}/{}", key, local_peer_id);
                        if put_ad_record(&mut swarm, &slot, local_peer_id, &addrs, AD_TTL) {
                            if !my_ads.contains(&key) {
                                my_ads.push(key.clone());
                            }
                            let _ = tx_state.send(StateUpdate::Advertised(key));
                        } else {
                            let _ = tx_state.send(StateUpdate::Log {
                                level: tui::LogLevel::Error,
                                message: format!("Advertise '{}' failed", key),
                            });
                        }
                    }
                    TuiCommand::Query(key) => {
                        // Phase 1: find nodes closest to the key in XOR space.
                        // Those nodes are responsible for storing "<key>/*" records.
                        let qid = swarm.behaviour_mut().kad.get_closest_peers(key.as_bytes().to_vec());
                        phase1.insert(qid, key);
                    }
                    TuiCommand::Quit => break,
                }
            }
            _ = readvertise_tick.tick() => {
                if !my_ads.is_empty() {
                    let addrs: Vec<String> = swarm.listeners().map(|a| a.to_string()).collect();
                    for key in &my_ads {
                        let slot = format!("{}/{}", key, local_peer_id);
                        put_ad_record(&mut swarm, &slot, local_peer_id, &addrs, AD_TTL);
                    }
                    info!("Re-advertised {} key(s)", my_ads.len());
                }
            }
            event = swarm.select_next_some() => {
                if let libp2p::swarm::SwarmEvent::Behaviour(
                    crate::behaviour::P2PBehaviourEvent::Kad(ref kad_event)
                ) = event {
                    match kad_event {
                        // ── Phase 1: closest peers found ─────────────────────
                        kad::Event::OutboundQueryProgressed {
                            id,
                            result: kad::QueryResult::GetClosestPeers(Ok(kad::GetClosestPeersOk { peers, .. })),
                            ..
                        } => {
                            if let Some(key) = phase1.remove(id) {
                                // Phase 2: fetch "<key>/<peer_id>" record for each candidate
                                let candidates: Vec<_> = peers.iter()
                                    .take(MAX_QUERY_RESULTS)
                                    .map(|p| p.peer_id.to_string())
                                    .collect();

                                if candidates.is_empty() {
                                    let _ = tx_state.send(StateUpdate::QueryResult {
                                        key,
                                        peers: vec![],
                                    });
                                } else {
                                    let mut fetch_ids = HashMap::new();
                                    for peer_id_str in &candidates {
                                        let slot = format!("{}/{}", key, peer_id_str);
                                        let qid = swarm.behaviour_mut().kad
                                            .get_record(kad::RecordKey::new(&slot.as_bytes()));
                                        fetch_ids.insert(qid, peer_id_str.clone());
                                        phase2_qid_to_key.insert(qid, key.clone());
                                    }
                                    pending_tui.insert(key.clone(), PendingTuiQuery {
                                        key: key.clone(),
                                        fetch_ids,
                                        results: vec![],
                                    });
                                }
                            }
                        }
                        // ── Phase 1: no peers found ──────────────────────────
                        kad::Event::OutboundQueryProgressed {
                            id,
                            result: kad::QueryResult::GetClosestPeers(Err(_)),
                            ..
                        } => {
                            if let Some(key) = phase1.remove(id) {
                                let _ = tx_state.send(StateUpdate::QueryResult {
                                    key,
                                    peers: vec![],
                                });
                            }
                        }
                        // ── Phase 2: record found for a candidate ────────────
                        kad::Event::OutboundQueryProgressed {
                            id,
                            result: kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FoundRecord(rec))),
                            ..
                        } => {
                            if let Some(key) = phase2_qid_to_key.remove(id) {
                                if let Some(pending) = pending_tui.get_mut(&key) {
                                    pending.fetch_ids.remove(id);
                                    let mut found = decode_ad_record(&rec.record);
                                    pending.results.append(&mut found);
                                    // Done when all fetches resolved or we hit the cap
                                    if pending.fetch_ids.is_empty() || pending.results.len() >= MAX_QUERY_RESULTS {
                                        if let Some(p) = pending_tui.remove(&key) {
                                            // Clean up any remaining pending fetches
                                            phase2_qid_to_key.retain(|_, k| k != &p.key);
                                            let peers: Vec<FoundPeer> = p.results.into_iter().take(MAX_QUERY_RESULTS).collect();
                                            let _ = tx_state.send(StateUpdate::QueryResult { key: p.key, peers });
                                        }
                                    }
                                }
                            }
                        }
                        // ── Phase 2: record not found for a candidate ────────
                        kad::Event::OutboundQueryProgressed {
                            id,
                            result: kad::QueryResult::GetRecord(Err(_)),
                            ..
                        } => {
                            if let Some(key) = phase2_qid_to_key.remove(id) {
                                if let Some(pending) = pending_tui.get_mut(&key) {
                                    pending.fetch_ids.remove(id);
                                    if pending.fetch_ids.is_empty() {
                                        if let Some(p) = pending_tui.remove(&key) {
                                            let peers: Vec<FoundPeer> = p.results.into_iter().take(MAX_QUERY_RESULTS).collect();
                                            let _ = tx_state.send(StateUpdate::QueryResult { key: p.key, peers });
                                        }
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }

                handle_swarm_event(
                    event,
                    discovered_peers,
                    port_protocol,
                    &mut swarm,
                    pending_queries,
                    Some(&tx_state),
                )
                .await;
            }
        }
    }

    let _ = tui_handle.await;

    Ok(())
}

/// Serialize and put an advertisement record into the DHT.
/// Returns true on success.
fn put_ad_record(
    swarm: &mut libp2p::Swarm<P2PBehaviour>,
    key: &str,
    peer_id: PeerId,
    addrs: &[String],
    ttl: Duration,
) -> bool {
    let value = serde_json::json!({
        "peer_id": peer_id.to_string(),
        "addrs": addrs,
    });
    let Ok(bytes) = serde_json::to_vec(&value) else { return false; };
    let expires = Some(std::time::Instant::now() + ttl);
    let record = kad::Record {
        key: kad::RecordKey::new(&key.as_bytes()),
        value: bytes,
        publisher: Some(peer_id),
        expires,
    };
    swarm.behaviour_mut().kad.put_record(record, kad::Quorum::One).is_ok()
}

/// Decode a DHT record value into a list of `FoundPeer`.
fn decode_ad_record(record: &kad::Record) -> Vec<FoundPeer> {
    let Ok(json) = serde_json::from_slice::<serde_json::Value>(&record.value) else {
        // Legacy: plain peer_id string
        return record.publisher.map(|p| FoundPeer { peer_id: p.to_string(), addrs: vec![] }).into_iter().collect();
    };
    let peer_id = json["peer_id"].as_str().unwrap_or("unknown").to_string();
    let addrs = json["addrs"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();
    vec![FoundPeer { peer_id, addrs }]
}

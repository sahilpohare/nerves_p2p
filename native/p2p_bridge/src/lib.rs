mod atoms;
mod behaviour;
mod commands;
mod config;
mod dht_state;
mod error;
mod events;
mod node;
mod policy;

use commands::Command;
use error::NifError;
use node::NodeHandle;
use rustler::{Binary, Encoder, LocalPid, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use tokio::sync::oneshot;

// ── Node lifecycle ───────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn start_node(config: HashMap<String, Term>) -> NifResult<ResourceArc<NodeHandle>> {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        node::start_node_inner(config)
    }));
    match result {
        Ok(Ok(handle)) => Ok(handle),
        Ok(Err(e)) => Err(NifError::Internal(e).into()),
        Err(_) => Err(NifError::NifPanic("panic caught in start_node".to_string()).into()),
    }
}

#[rustler::nif]
fn stop_node(handle: ResourceArc<NodeHandle>) -> rustler::Atom {
    let _ = handle.cmd_tx.try_send(Command::Shutdown);
    atoms::ok()
}

#[rustler::nif]
fn register_event_handler(handle: ResourceArc<NodeHandle>, pid: LocalPid) -> rustler::Atom {
    let _ = handle.cmd_tx.try_send(Command::RegisterEventHandler { pid });
    atoms::ok()
}

#[rustler::nif]
fn get_peer_id(handle: ResourceArc<NodeHandle>) -> String {
    handle.peer_id.clone()
}

// ── Synchronous queries ──────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn connected_peers(handle: ResourceArc<NodeHandle>) -> NifResult<Vec<String>> {
    let peers = query_typed(&handle, |tx| Command::ConnectedPeers { reply: tx })?;
    Ok(peers.into_iter().map(|p| p.to_base58()).collect())
}

#[rustler::nif(schedule = "DirtyIo")]
fn listening_addrs(handle: ResourceArc<NodeHandle>) -> NifResult<Vec<String>> {
    let addrs = query_typed(&handle, |tx| Command::ListeningAddrs { reply: tx })?;
    Ok(addrs.into_iter().map(|a| a.to_string()).collect())
}

#[rustler::nif(schedule = "DirtyIo")]
fn bandwidth_stats(handle: ResourceArc<NodeHandle>) -> NifResult<(rustler::Atom, u64, u64)> {
    let (bin, bout) = query_typed(&handle, |tx| Command::BandwidthStats { reply: tx })?;
    Ok((atoms::ok(), bin, bout))
}

#[rustler::nif(schedule = "DirtyIo")]
fn prometheus_metrics(handle: ResourceArc<NodeHandle>) -> NifResult<(rustler::Atom, String)> {
    let registry = handle
        .metrics_registry
        .lock()
        .map_err(|e| NifError::Internal(format!("metrics lock poisoned: {e}")))?;
    let mut text = String::new();
    prometheus_client::encoding::text::encode(&mut text, &registry)
        .map_err(|e| NifError::Internal(format!("encode metrics: {e}")))?;
    Ok((atoms::ok(), text))
}

// ── Fire-and-forget commands ─────────────────────────────────────

#[rustler::nif]
fn dial(handle: ResourceArc<NodeHandle>, addr: String) -> NifResult<rustler::Atom> {
    let multiaddr = addr.parse::<libp2p::Multiaddr>().map_err(NifError::from)?;
    send_typed(&handle, Command::Dial { addr: multiaddr })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn publish(handle: ResourceArc<NodeHandle>, topic: String, data: Binary) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::Publish { topic, data: data.as_slice().to_vec() })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn subscribe(handle: ResourceArc<NodeHandle>, topic: String) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::Subscribe { topic })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn unsubscribe(handle: ResourceArc<NodeHandle>, topic: String) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::Unsubscribe { topic })?;
    Ok(atoms::ok())
}

// ── GossipSub advanced ───────────────────────────────────────────

#[rustler::nif(schedule = "DirtyCpu")]
fn gossipsub_mesh_peers(
    handle: ResourceArc<NodeHandle>,
    topic: String,
) -> NifResult<(rustler::Atom, Vec<String>)> {
    let peers = query_typed(&handle, |tx| Command::GossipsubMeshPeers { topic, reply: tx })?;
    Ok((atoms::ok(), peers.into_iter().map(|p| p.to_base58()).collect()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gossipsub_all_peers(handle: ResourceArc<NodeHandle>) -> NifResult<(rustler::Atom, Vec<String>)> {
    let peers = query_typed(&handle, |tx| Command::GossipsubAllPeers { reply: tx })?;
    Ok((atoms::ok(), peers.into_iter().map(|p| p.to_base58()).collect()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gossipsub_peer_score(
    handle: ResourceArc<NodeHandle>,
    peer_id_str: String,
) -> NifResult<(rustler::Atom, f64)> {
    let peer_id: libp2p::PeerId = peer_id_str.parse().map_err(NifError::from)?;
    let score = query_typed(&handle, |tx| Command::GossipsubPeerScore { peer_id, reply: tx })?;
    Ok((atoms::ok(), score.unwrap_or(0.0)))
}

// ── DHT ──────────────────────────────────────────────────────────

#[rustler::nif]
fn dht_put(handle: ResourceArc<NodeHandle>, key: Binary, value: Binary) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::DhtPut {
        key: key.as_slice().to_vec(),
        value: value.as_slice().to_vec(),
    })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn dht_get(handle: ResourceArc<NodeHandle>, key: Binary) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::DhtGet { key: key.as_slice().to_vec() })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn dht_find_peer(handle: ResourceArc<NodeHandle>, peer_id_str: String) -> NifResult<rustler::Atom> {
    let peer_id = peer_id_str.parse::<libp2p::PeerId>().map_err(NifError::from)?;
    send_typed(&handle, Command::DhtFindPeer { peer_id })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn dht_provide(handle: ResourceArc<NodeHandle>, key: Binary) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::DhtProvide { key: key.as_slice().to_vec() })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn dht_find_providers(handle: ResourceArc<NodeHandle>, key: Binary) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::DhtFindProviders { key: key.as_slice().to_vec() })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn dht_bootstrap(handle: ResourceArc<NodeHandle>) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::DhtBootstrap)?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
fn kad_export_routing_table<'a>(
    env: rustler::Env<'a>,
    handle: ResourceArc<NodeHandle>,
) -> NifResult<(rustler::Atom, Binary<'a>)> {
    let result = query_typed(&handle, |tx| Command::DhtExportRoutingTable { reply: tx })?;
    let entries = result.map_err(|()| NifError::DhtNotEnabled)?;
    let bytes = dht_state::encode(&entries);
    let mut owned = rustler::OwnedBinary::new(bytes.len())
        .ok_or_else(|| NifError::Internal(format!("alloc {} bytes", bytes.len())))?;
    owned.as_mut_slice().copy_from_slice(&bytes);
    Ok((atoms::ok(), Binary::from_owned(owned, env)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn kad_import_routing_table(
    handle: ResourceArc<NodeHandle>,
    data: Binary,
) -> NifResult<(rustler::Atom, u64)> {
    let entries = dht_state::decode(data.as_slice()).map_err(|e| match e {
        dht_state::DhtStateError::InputTooLarge { got, max } => NifError::InputTooLarge { got, max },
        dht_state::DhtStateError::Truncated { offset, need } => {
            NifError::Internal(format!("truncated at offset {offset}, need {need}"))
        }
        dht_state::DhtStateError::BadMagic { .. } => NifError::Internal("bad magic header".to_string()),
        dht_state::DhtStateError::UnsupportedVersion { version } => {
            NifError::Internal(format!("unsupported wire version {version}"))
        }
    })?;
    let result = query_typed(&handle, |tx| Command::DhtImportRoutingTable { entries, reply: tx })?;
    let count = result.map_err(|()| NifError::DhtNotEnabled)?;
    Ok((atoms::ok(), count as u64))
}

// ── Request-Response RPC ─────────────────────────────────────────

#[rustler::nif(schedule = "DirtyCpu")]
fn rpc_send_request(
    handle: ResourceArc<NodeHandle>,
    peer_id_str: String,
    data: Binary,
) -> NifResult<(rustler::Atom, String)> {
    let peer_id: libp2p::PeerId = peer_id_str.parse().map_err(NifError::from)?;
    let (tx, rx) = oneshot::channel();
    send_typed(&handle, Command::RpcSendRequest {
        peer_id,
        data: data.as_slice().to_vec(),
        reply: tx,
    })?;
    let req_id = rx.blocking_recv()
        .map_err(|_| Into::<rustler::Error>::into(NifError::NodeStopped))?;
    Ok((atoms::ok(), req_id))
}

#[rustler::nif]
fn rpc_send_response(
    handle: ResourceArc<NodeHandle>,
    channel_id: String,
    data: Binary,
) -> NifResult<rustler::Atom> {
    send_typed(&handle, Command::RpcSendResponse {
        channel_id,
        data: data.as_slice().to_vec(),
    })?;
    Ok(atoms::ok())
}

// ── Relay ────────────────────────────────────────────────────────

#[rustler::nif]
fn listen_via_relay(handle: ResourceArc<NodeHandle>, relay_addr: String) -> NifResult<rustler::Atom> {
    let addr = relay_addr.parse::<libp2p::Multiaddr>().map_err(NifError::from)?;
    send_typed(&handle, Command::ListenViaRelay { relay_addr: addr })?;
    Ok(atoms::ok())
}

// ── Rendezvous ───────────────────────────────────────────────────

#[rustler::nif]
fn rendezvous_register(
    handle: ResourceArc<NodeHandle>,
    namespace: String,
    ttl: u64,
    rendezvous_peer_str: String,
) -> NifResult<rustler::Atom> {
    let rendezvous_peer = rendezvous_peer_str.parse::<libp2p::PeerId>().map_err(NifError::from)?;
    send_typed(&handle, Command::RendezvousRegister { namespace, ttl, rendezvous_peer })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn rendezvous_discover(
    handle: ResourceArc<NodeHandle>,
    namespace: String,
    rendezvous_peer_str: String,
) -> NifResult<rustler::Atom> {
    let rendezvous_peer = rendezvous_peer_str.parse::<libp2p::PeerId>().map_err(NifError::from)?;
    send_typed(&handle, Command::RendezvousDiscover { namespace, rendezvous_peer })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn rendezvous_unregister(
    handle: ResourceArc<NodeHandle>,
    namespace: String,
    rendezvous_peer_str: String,
) -> NifResult<rustler::Atom> {
    let rendezvous_peer = rendezvous_peer_str.parse::<libp2p::PeerId>().map_err(NifError::from)?;
    send_typed(&handle, Command::RendezvousUnregister { namespace, rendezvous_peer })?;
    Ok(atoms::ok())
}

// ── Keypair ──────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyCpu")]
fn generate_keypair<'a>(env: rustler::Env<'a>) -> rustler::Term<'a> {
    let keypair = libp2p::identity::Keypair::generate_ed25519();
    let peer_id = keypair.public().to_peer_id().to_base58();
    let public_key_bytes = keypair.public().encode_protobuf();

    match keypair.to_protobuf_encoding() {
        Ok(protobuf_bytes) => {
            let pub_bin = make_binary(env, &public_key_bytes);
            let proto_bin = make_binary(env, &protobuf_bytes);
            (atoms::ok(), pub_bin, peer_id, proto_bin).encode(env)
        }
        Err(_) => {
            let empty = make_binary(env, &[]);
            (atoms::error(), empty, "", empty).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn keypair_from_protobuf<'a>(env: rustler::Env<'a>, bytes: Binary) -> rustler::Term<'a> {
    if bytes.len() > error::MAX_KEYPAIR_BYTES {
        let err = NifError::InputTooLarge { got: bytes.len(), max: error::MAX_KEYPAIR_BYTES };
        return (atoms::error(), err).encode(env);
    }
    match libp2p::identity::Keypair::from_protobuf_encoding(bytes.as_slice()) {
        Ok(keypair) => {
            let peer_id = keypair.public().to_peer_id().to_base58();
            let public_key_bytes = keypair.public().encode_protobuf();
            let pub_bin = make_binary(env, &public_key_bytes);
            (atoms::ok(), pub_bin, peer_id).encode(env)
        }
        Err(e) => {
            let err = NifError::InvalidKeypair(e.to_string());
            (atoms::error(), err).encode(env)
        }
    }
}

fn make_binary<'a>(env: rustler::Env<'a>, data: &[u8]) -> rustler::Binary<'a> {
    let mut bin = rustler::NewBinary::new(env, data.len());
    bin.as_mut_slice().copy_from_slice(data);
    bin.into()
}

// ── Helpers ──────────────────────────────────────────────────────

fn send_typed(handle: &ResourceArc<NodeHandle>, cmd: Command) -> Result<(), NifError> {
    handle.cmd_tx.try_send(cmd).map_err(|e| match e {
        tokio::sync::mpsc::error::TrySendError::Full(_) => NifError::ChannelFull,
        tokio::sync::mpsc::error::TrySendError::Closed(_) => NifError::NodeStopped,
    })
}

fn query_typed<T>(
    handle: &ResourceArc<NodeHandle>,
    make_cmd: impl FnOnce(oneshot::Sender<T>) -> Command,
) -> Result<T, NifError> {
    let (tx, rx) = oneshot::channel();
    handle.cmd_tx.try_send(make_cmd(tx)).map_err(|e| match e {
        tokio::sync::mpsc::error::TrySendError::Full(_) => NifError::ChannelFull,
        tokio::sync::mpsc::error::TrySendError::Closed(_) => NifError::NodeStopped,
    })?;
    rx.blocking_recv().map_err(|_| NifError::NodeStopped)
}

// ── Init ─────────────────────────────────────────────────────────

rustler::init!("Elixir.ElixirRpc.P2P.Native.Nif");

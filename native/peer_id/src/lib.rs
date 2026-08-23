use rustler::NifResult;

#[rustler::nif]
fn generate_peer_id() -> NifResult<String> {
    let keypair = libp2p::identity::Keypair::generate_ed25519();
    let peer_id = libp2p::PeerId::from(keypair.public());
    Ok(peer_id.to_string())
}

rustler::init!("Elixir.ElixirRpc.PeerId");

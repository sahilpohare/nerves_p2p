use libp2p::{dcutr, identify, kad, mdns, ping, relay};
use std::time::Duration;

/// Main P2P Bridge behavior
///
/// This combines essential libp2p behaviors for:
/// - Peer identification (identify)
/// - Local network discovery (mDNS)
/// - NAT traversal via relay (relay_client)
/// - Direct connection upgrade (dcutr)
/// - Keepalive / liveness detection (ping)
#[derive(libp2p::swarm::NetworkBehaviour)]
pub struct P2PBehaviour {
    pub identify: identify::Behaviour,
    pub mdns: mdns::tokio::Behaviour,
    pub relay_client: relay::client::Behaviour,
    pub dcutr: dcutr::Behaviour,
    pub kad: kad::Behaviour<kad::store::MemoryStore>,
    pub ping: ping::Behaviour,
}

impl P2PBehaviour {
    pub fn new(
        keypair: &libp2p::identity::Keypair,
        relay_client: relay::client::Behaviour,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let peer_id = keypair.public().to_peer_id();

        let identify = identify::Behaviour::new(identify::Config::new(
            "/elixir_rpc/0.1.0".to_string(),
            keypair.public(),
        ));

        let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id)?;

        let dcutr = dcutr::Behaviour::new(peer_id);

        let mut kad_config = kad::Config::default();
        kad_config.set_query_timeout(Duration::from_secs(60));
        kad_config.set_kbucket_inserts(kad::BucketInserts::OnConnected);

        let kad = kad::Behaviour::with_config(
            peer_id,
            kad::store::MemoryStore::new(peer_id),
            kad_config,
        );

        // Ping every 15s to keep connections alive and detect dead peers
        let ping = ping::Behaviour::new(
            ping::Config::new().with_interval(Duration::from_secs(15)),
        );

        Ok(Self {
            identify,
            mdns,
            relay_client,
            dcutr,
            kad,
            ping,
        })
    }
}

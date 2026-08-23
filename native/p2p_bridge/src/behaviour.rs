use libp2p::{
    autonat, connection_limits, dcutr, gossipsub, identify, kad, mdns,
    memory_connection_limits, ping, relay, rendezvous, request_response,
    swarm::{behaviour::toggle::Toggle, NetworkBehaviour},
    upnp,
};

#[derive(NetworkBehaviour)]
pub struct NodeBehaviour {
    // Infrastructure — always present
    pub connection_limits: connection_limits::Behaviour,
    pub memory_limits: memory_connection_limits::Behaviour,
    pub identify: identify::Behaviour,
    pub ping: ping::Behaviour,

    // Application protocols — always present
    pub gossipsub: gossipsub::Behaviour,
    pub request_response: request_response::cbor::Behaviour<Vec<u8>, Vec<u8>>,

    // Optional protocols — controlled by enable_* flags
    pub kademlia: Toggle<kad::Behaviour<kad::store::MemoryStore>>,
    pub mdns: Toggle<mdns::tokio::Behaviour>,
    pub rendezvous_client: Toggle<rendezvous::client::Behaviour>,
    pub rendezvous_server: Toggle<rendezvous::server::Behaviour>,

    // NAT traversal
    pub relay_client: relay::client::Behaviour,
    pub relay_server: Toggle<relay::Behaviour>,
    pub dcutr: Toggle<dcutr::Behaviour>,
    pub autonat: Toggle<autonat::Behaviour>,
    pub autonat_server: Toggle<autonat::v2::server::Behaviour>,
    pub upnp: Toggle<upnp::tokio::Behaviour>,
}

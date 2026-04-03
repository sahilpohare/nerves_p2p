use anyhow::Result;
use libp2p::{kad::PeerInfo, multiaddr::Protocol, Multiaddr};
use serde::{Deserialize, Serialize};
use std::{
    io::{self, Write},
    net::IpAddr,
};

/// Commands sent from Elixir to Rust
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    /// Get this node's PeerID
    GetPeerId,
    /// Get current listen addresses
    GetListenAddrs,
    /// Dial a peer
    Dial { multiaddr: String },
    /// Get list of connected peers
    GetConnectedPeers,
    /// Ping to check if process is alive
    Ping,
    /// Advertise capabilities to the network
    /// [{ :gpu, 5000 }] | [{ :cpu, 5000 }] | [{ :anchor, None}]
    Advertise {
        capabilities: Vec<(String, Option<i32>)>,
    },
    /// Query peers for a specific capability, 0 or None indicates any capability.
    /// `query_ref` is an opaque string echoed back in `PeersFound` so the caller can
    /// match the response to the originating request.
    QueryPeers {
        capabilities: Vec<(String, Option<i32>)>,
        limit: Option<i32>,
        /// Caller-supplied correlation token, echoed back in PeersFound
        query_ref: Option<String>,
    },
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct IpPort {
    pub ip: IpAddr,
    pub port: u16,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct PartisanCompatiblePeerID {
    pub peer_id: String,
    pub addrs: Vec<IpPort>,
}

impl PartisanCompatiblePeerID {
    fn get_ip_and_tcp_port(addr: &Multiaddr) -> Option<(IpAddr, u16)> {
        let mut ip = None;
        let mut port = None;

        for proto in addr.iter() {
            match proto {
                Protocol::Ip4(ip4) => ip = Some(IpAddr::V4(ip4)),
                Protocol::Ip6(ip6) => ip = Some(IpAddr::V6(ip6)),
                Protocol::Tcp(p) => port = Some(p),
                _ => (),
            }
        }

        match (ip, port) {
            (Some(ip), Some(port)) => Some((ip, port)),
            _ => None,
        }
    }

    pub fn from_peer_info(peer_info: PeerInfo) -> Self {
        let ip_pairs = peer_info
            .addrs
            .iter()
            .filter_map(Self::get_ip_and_tcp_port)
            .map(|(ip, port)| IpPort { ip, port })
            .collect::<Vec<_>>();

        Self {
            peer_id: peer_info.peer_id.to_string(),
            addrs: ip_pairs,
        }
    }
}

/// Events sent from Rust to Elixir
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(dead_code)]
pub enum Event {
    /// Response to GetPeerId
    PeerId { peer_id: String },
    /// Response to GetListenAddrs
    ListenAddrs { addrs: Vec<String> },
    /// Response to GetConnectedPeers
    ConnectedPeers { peers: Vec<String> },
    /// Now listening on address
    ListeningOn { multiaddr: String },
    /// Peer discovered via mDNS/DHT
    PeerDiscovered {
        peer_id: String,
        multiaddr: String,
        protocol: String,
    },
    /// NAT status detected
    NatStatus { status: String },
    /// UPnP port mapping successful
    UpnpMapped { external_addr: String },
    /// Connection established with peer
    ConnectionEstablished { peer_id: String, multiaddr: String },
    /// Connection closed
    ConnectionClosed { peer_id: String },
    /// Dialing peer
    DialingPeer { multiaddr: String },
    /// Pong response
    Pong,
    /// Error occurred
    Error { message: String },
    /// Peers found via DHT query
    PeersFound {
        /// Echoed from the originating QueryPeers command, or None for unsolicited results
        query_ref: Option<String>,
        peers: Vec<PartisanCompatiblePeerID>,
    },
    /// Advertising capabilities to DHT
    Advertising {
        capabilities: Vec<(String, Option<i32>)>,
    },
}

/// Port protocol handler for stdin/stdout communication
pub struct PortProtocol {
    stdout: io::Stdout,
}

impl Default for PortProtocol {
    fn default() -> Self {
        Self {
            stdout: io::stdout(),
        }
    }
}

impl PortProtocol {
    pub fn new() -> Self {
        Self::default()
    }

    /// Send an event to Elixir via stdout
    /// Events are JSON-encoded, one per line
    pub fn send_event(&mut self, event: Event) -> Result<()> {
        let json = serde_json::to_string(&event)?;
        writeln!(self.stdout, "{}", json)?;
        self.stdout.flush()?;
        Ok(())
    }
}

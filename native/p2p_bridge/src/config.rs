use clap::Parser;
use libp2p::Multiaddr;

/// P2P Bridge — libp2p port process for Elixir RPC mesh networking
#[derive(Debug, Clone, Parser)]
#[command(name = "p2p_bridge", about = "libp2p bridge for Elixir P2P mesh")]
pub struct Config {
    /// Custom listen addresses (empty means use defaults: 0.0.0.0:0 and [::]:0)
    #[arg(long = "listen", value_name = "MULTIADDR")]
    pub listen_addrs: Vec<Multiaddr>,

    /// Generate a fresh peer identity each run without reading or writing ~/.peer_id
    #[arg(long, default_value_t = false)]
    pub transient: bool,
}

import Config

# Add configuration that is only needed when running on the host here.
config :logger, level: :info

# Use the real NIF on host — Rustler compiles p2p_bridge for native dev/test.
# Set native_module: ElixirRpc.P2P.Native.Mock in a specific test if isolation is needed.
config :elixir_rpc, native_module: ElixirRpc.P2P.Native.Nif

# Tests exercise the legacy libp2p path; consumers default to :none.
config :elixir_rpc, network_mode: :legacy

# Partisan configuration for development
config :partisan,
  peer_service_manager: :partisan_hyparview_peer_service_manager,
  hyparview: [
    active_min_size: 3,
    active_max_size: 6,
    passive_max_size: 30,
    shuffle_interval: 10_000,
    random_promotion_interval: 5_000
  ],
  channels: [:membership, :rpc, :discovery],
  broadcast: true,
  connection_jitter: 1000,
  tls: false,
  name: Node.self(),
  listen_addrs: [%{ip: {127, 0, 0, 1}, port: 10200}],
  peer_discovery: true,
  peer_discovery_strategy: :partisan_mdns_peer_discovery

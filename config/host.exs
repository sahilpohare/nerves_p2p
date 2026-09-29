import Config

# Add configuration that is only needed when running on the host here.
config :logger, level: :info

# Use the real NIF on host — Rustler compiles p2p_bridge for native dev/test.
# Set native_module: ElixirRpc.P2P.Native.Mock in a specific test if isolation is needed.
config :elixir_rpc, native_module: ElixirRpc.P2P.Native.Nif

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://hexdocs.pm/nerves_runtime/readme.html#using-nerves_runtime-in-tests
       # https://hexdocs.pm/nerves_runtime/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

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

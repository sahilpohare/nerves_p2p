import Config

# Add configuration that is only needed when running on the host here.

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
  # Peer service manager (handles membership)
  peer_service_manager: :partisan_pluggable_peer_service_manager,
  # Use full mesh topology for development
  partisan_peer_service_manager: :partisan_hyparview_peer_service_manager,
  # Channels configuration
  channels: [:membership, :rpc, :discovery],
  # Enable broadcast trees for efficient multicast
  broadcast: true,
  # Connection backlog
  connection_jitter: 1000,
  # Disable TLS for local development
  tls: false,
  # Name for this node (will be overridden at runtime)
  name: :"dev@127.0.0.1",
  # Listen port
  listen_addrs: [%{ip: {127, 0, 0, 1}, port: 10200}]

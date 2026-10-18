import Config

network_mode =
  case System.get_env("ELIXIR_RPC_NETWORK_MODE") do
    "iroh" -> :iroh
    "legacy" -> :legacy
    _ -> Application.get_env(:elixir_rpc, :network_mode, :legacy)
  end

config :elixir_rpc, network_mode: network_mode

if network_mode == :iroh do
  configured = Application.get_env(:elixir_rpc, :iroh_discovery, [])

  config :elixir_rpc, :iroh_discovery,
    executable:
      System.get_env("IROH_DISCOVERY_BIN") ||
        Keyword.get(configured, :executable, "/usr/bin/iroh_discovery_port"),
    data_dir:
      System.get_env("IROH_DISCOVERY_DATA_DIR") ||
        Keyword.get(configured, :data_dir, "/data/iroh"),
    fleet_id: System.get_env("IROH_FLEET_ID") || Keyword.fetch!(configured, :fleet_id),
    node_name: System.get_env("IROH_NODE_NAME") || Keyword.fetch!(configured, :node_name)
end

get_available_port = fn ->
  {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
  {:ok, port} = :inet.port(socket)
  :gen_tcp.close(socket)
  port
end

# Generate a unique node name using crypto — available at runtime.exs time
# unlike NIFs. The actual libp2p PeerID format is used by the NIF at app start,
# but for Partisan's internal use any unique stable name works.
generate_node_name = fn host ->
  id = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  :"#{id}@#{host}"
end

if config_env() == :dev or config_env() == :test do
  available_port = get_available_port.()
  node_name = generate_node_name.("127.0.0.1")

  config :partisan,
    name: node_name,
    listen_addrs: [%{ip: {127, 0, 0, 1}, port: available_port}]

  IO.puts("Partisan runtime config: node=#{node_name} port=#{available_port}")
end

if config_env() == :prod and Application.get_env(:nerves, :target) != :host do
  available_port = get_available_port.()

  hostname =
    case :inet.gethostname() do
      {:ok, h} -> to_string(h)
      _ -> "localhost"
    end

  iroh_config = Application.get_env(:elixir_rpc, :iroh_discovery, [])
  node_name = iroh_config |> Keyword.get(:node_name, "gpu@#{hostname}") |> String.to_atom()

  config :partisan,
    name: node_name,
    listen_addrs: [%{ip: {0, 0, 0, 0}, port: available_port}]

  IO.puts("Partisan runtime config: node=#{node_name} port=#{available_port}")
end

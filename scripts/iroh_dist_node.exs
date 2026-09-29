[role, root, daemon, fleet] = System.argv()
node_name = "#{role}@127.0.0.1"
node = String.to_atom(node_name)
other_role = if role == "a", do: "b", else: "a"
other_name = "#{other_role}@127.0.0.1"
other_node = String.to_atom(other_name)

Application.ensure_all_started(:crypto)
Application.ensure_all_started(:logger)

data_dir = Path.join(root, role)
File.mkdir_p!(data_dir)

{:ok, _port} =
  ElixirRpc.IrohDiscovery.Port.start_link(
    name: ElixirRpc.IrohDiscovery,
    executable: daemon,
    data_dir: data_dir,
    fleet_id: fleet,
    node_name: node_name
  )

read_term = fn path ->
  Stream.repeatedly(fn -> File.read(path) end)
  |> Enum.find_value(fn
    {:ok, bytes} -> :erlang.binary_to_term(bytes)
    _ -> Process.sleep(25) && nil
  end)
end

write_term = fn path, term ->
  temporary = path <> ".#{role}.tmp"
  File.write!(temporary, :erlang.term_to_binary(term))
  File.rename!(temporary, path)
end

bootstrap =
  case role do
    "a" -> nil
    "b" -> read_term.(Path.join(root, "a-endpoint"))
  end

network_options =
  case bootstrap do
    nil ->
      %{"dns" => false, "relay" => false, "mdns" => true, "dht" => false}

    endpoint ->
      %{
        "bootstrap" => endpoint,
        "dns" => false,
        "relay" => false,
        "mdns" => true,
        "dht" => false
      }
  end

{:ok, %{"endpoint_address" => endpoint}} =
  ElixirRpc.IrohDiscovery.Port.network_start(ElixirRpc.IrohDiscovery, network_options, 15_000)

write_term.(Path.join(root, "#{role}-endpoint"), endpoint)

{:ok, %{"envelope" => envelope}} =
  ElixirRpc.IrohDiscovery.Port.publish(ElixirRpc.IrohDiscovery, %{
    "ttl_ms" => 60_000,
    "partisan_ip" => "127.0.0.1",
    "partisan_port" => if(role == "a", do: 19_001, else: 19_002),
    "capabilities" => %{},
    "load" => %{"running" => 0, "capacity" => 1}
  })

identity = %{"endpoint_id" => endpoint["endpoint_id"], "envelope" => envelope}
write_term.(Path.join(root, "#{role}-identity"), identity)
other = read_term.(Path.join(root, "#{other_role}-identity"))

case ElixirRpc.IrohDiscovery.Port.ingest(ElixirRpc.IrohDiscovery, %{
       "endpoint_id" => other["endpoint_id"],
       "node_name" => other_name,
       "envelope" => other["envelope"]
     }) do
  {:ok, _} -> :ok
  {:error, "stale_sequence"} -> :ok
end

Application.put_env(:elixir_rpc, :iroh_discovery, node_name: node_name)
:ok = :partisan_config.set(:name, node)
:ok = ElixirRpc.IrohDistribution.start()
Node.set_cookie(:iroh_dist_test)

IO.inspect(
  %{
    role: role,
    node: node(),
    proto_dist: :init.get_argument(:proto_dist),
    listener: Process.whereis(:iroh_dist_listener)
  },
  label: "iroh_dist_ready"
)

write_term.(Path.join(root, "#{role}-ready"), :ready)

case role do
  "a" ->
    receive do
      :stop -> :ok
    after
      60_000 -> :ok
    end

  "b" ->
    _ = read_term.(Path.join(root, "a-ready"))
    ping = Node.ping(other_node)
    IO.inspect(ping, label: "iroh_dist_ping")
    rpc = :rpc.call(other_node, :erlang, :+, [40, 2])
    large_rpc = :rpc.call(other_node, :erlang, :byte_size, [:binary.copy(<<1>>, 128 * 1024)])
    remote_pid = Node.spawn(other_node, :timer, :sleep, [60_000])
    monitor = Process.monitor(remote_pid)
    Process.exit(remote_pid, :kill)

    reason =
      receive do
        {:DOWN, ^monitor, :process, ^remote_pid, down_reason} -> down_reason
      after
        5_000 -> :timeout
      end

    result = %{
      ping: ping,
      rpc: rpc,
      large_rpc: large_rpc,
      remote_pid_node: node(remote_pid),
      monitor: reason
    }

    write_term.(Path.join(root, "result"), result)
    Process.sleep(250)
end

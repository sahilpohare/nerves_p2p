# One comrade on the mesh, for side-by-side terminals.
#
#   export IROH_FLEET_ID=<same 64-hex value in both terminals>
#   iex --name a@127.0.0.1 --cookie comrade -S mix run --no-start examples/talk/comrade.exs
#   iex --name b@127.0.0.1 --cookie comrade -S mix run --no-start examples/talk/comrade.exs
#
# Each terminal prints a line whenever it discovers a comrade or sees one's
# signed record change. Then, in the IEx prompts:
#
#   b> ElixirRpc.Network.advertise(gpu: true)
#   a> ElixirRpc.Network.spawn([gpu: true], {ElixirRpc.DemoWorker, :report, [self(), :job]})
#   a> flush()   # {:job, {:demo_result, :job, :"b@127.0.0.1"}}

alias ElixirRpc.{CodeIdentity, DemoWorker, Network}

name = Atom.to_string(node())

{:ok, socket} = :gen_tcp.listen(0, reuseaddr: true)
{:ok, partisan_port} = :inet.port(socket)
:gen_tcp.close(socket)

# Same config as the Livebook's comrade_env: Partisan named after this node,
# Iroh discovery + Horde, and a publisher for our signed capability record.
Application.put_all_env(
  partisan: [
    name: node(),
    listen_addrs: [%{ip: {127, 0, 0, 1}, port: partisan_port}],
    peer_service_manager: :partisan_hyparview_peer_service_manager,
    hyparview: [active_min_size: 3, active_max_size: 6, passive_max_size: 30],
    channels: [:membership, :rpc, :discovery],
    tls: false
  ],
  elixir_rpc: [
    network_mode: :iroh,
    iroh_discovery: [
      data_dir: Path.join(System.tmp_dir!(), "comrade-#{name}"),
      fleet_id: System.fetch_env!("IROH_FLEET_ID"),
      node_name: name
    ],
    talk_worker: [capabilities: %{}],
    placeable_modules: [DemoWorker],
    # First spawn joins Partisan and waits for Horde membership to sync.
    handoff_timeout: 15_000,
    # Provisioned trust: which advertised names we may place work on.
    authorized_nodes: %{"a@127.0.0.1" => :"a@127.0.0.1", "b@127.0.0.1" => :"b@127.0.0.1"}
  ]
)

{:ok, _} = Application.ensure_all_started(:elixir_rpc)
:logger.set_primary_config(:level, :warning)

# Print each comrade the first time we see it, and whenever it advertises
# different capabilities (records republish every 3 s; unchanged ones stay quiet).
watch = fn watch, seen ->
  seen =
    case Network.capabilities() do
      {:ok, %{"peers" => peers}} ->
        for %{"node_name" => peer, "sequence" => seq} = p <- peers,
            peer != name,
            caps = Map.delete(p["capabilities"], "code"),
            seen[peer] != caps,
            reduce: seen do
          acc ->
            verb = if Map.has_key?(acc, peer), do: "updated", else: "discovered"

            IO.puts(
              IO.ANSI.format([
                :green,
                "\n>> #{verb} comrade #{peer}",
                :reset,
                "  capabilities=#{inspect(caps)}  signed seq=#{seq}"
              ])
            )

            Map.put(acc, peer, caps)
        end

      _ ->
        seen
    end

  Process.sleep(500)
  watch.(watch, seen)
end

spawn(fn -> watch.(watch, %{}) end)

IO.puts("comrade #{name} is on the mesh; advertising #{inspect(CodeIdentity.advertised())}")

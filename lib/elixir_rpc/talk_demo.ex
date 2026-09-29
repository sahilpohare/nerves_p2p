defmodule ElixirRpc.TalkDemo do
  @moduledoc "Runs staged local or remote Iroh discovery and Horde placement demos."

  alias ElixirRpc.IrohDiscovery.Port
  alias ElixirRpc.Network

  @default_bin Path.expand(
                 "../../native/iroh_discovery/target/debug/iroh_discovery_port",
                 __DIR__
               )

  @spec run(keyword(), (map() -> any())) :: :ok
  def run(opts, emit_fn) when is_list(opts) and is_function(emit_fn, 1) do
    runtime = start_runtime()

    executable =
      Keyword.get(opts, :executable, System.get_env("IROH_DISCOVERY_BIN", @default_bin))

    root = Keyword.get_lazy(opts, :root, &temporary_root/0)
    fleet = Keyword.get_lazy(opts, :fleet, &fleet_id/0)
    partisan_name = Keyword.get(opts, :partisan_name, Atom.to_string(:partisan.node()))

    unless File.exists?(executable),
      do: raise("Iroh daemon not found at #{executable}; set IROH_DISCOVERY_BIN")

    try do
      run_mode(
        Keyword.get(opts, :mode, :local),
        executable,
        root,
        fleet,
        partisan_name,
        opts,
        emit_fn
      )
    after
      stop_runtime(runtime)
      File.rm_rf(root)
    end
  end

  defp run_mode(:local, executable, root, fleet, partisan_name, _opts, emit) do
    {:ok, finder} = start_port(executable, Path.join(root, "finder"), fleet, "finder@talk.local")
    {:ok, gpu} = start_port(executable, Path.join(root, "gpu"), fleet, partisan_name)

    try do
      local_demo(finder, gpu, partisan_name, emit)
    after
      stop_port(finder)
      stop_port(gpu)
    end
  end

  defp run_mode(:remote, executable, root, fleet, partisan_name, opts, emit) do
    {:ok, finder} = start_port(executable, Path.join(root, "finder"), fleet, "finder@talk.local")

    try do
      remote_demo(finder, partisan_name, opts, emit)
    after
      stop_port(finder)
    end
  end

  defp local_demo(finder, gpu, partisan_name, emit) do
    emit.(
      event(
        "stage",
        "discovery",
        "running",
        "STAGE 1: REAL IROH DISCOVERY (two daemon processes)"
      )
    )

    {:ok, %{"endpoint_id" => finder_id}} = Port.identity(finder)
    {:ok, %{"endpoint_id" => gpu_id}} = Port.identity(gpu)

    emit.(
      event("identities", "discovery", "ok", "Iroh endpoint identities loaded", %{
        daemons: %{
          finder: %{endpoint_id: finder_id, status: "active"},
          gpu: %{endpoint_id: gpu_id, status: "active"}
        }
      })
    )

    {:ok, _} = Port.authorize(finder, gpu_id, partisan_name)
    {:ok, _} = Port.authorize(gpu, finder_id, "finder@talk.local")
    {:ok, %{"endpoint_address" => finder_address}} = Port.network_start(finder)
    {:ok, %{"endpoint_address" => gpu_address}} = Port.network_start(gpu, finder_address)

    {partisan_ip, partisan_port} = partisan_endpoint()

    {:ok, %{"sequence" => sequence}} =
      Port.publish(gpu, %{
        "ttl_ms" => 60_000,
        "partisan_ip" => partisan_ip,
        "partisan_port" => partisan_port,
        "capabilities" => %{"gpu" => true},
        "load" => %{"running" => 0, "capacity" => 1}
      })

    predicates = [%{"op" => "equals", "name" => "gpu", "value" => true}]
    {:ok, %{"peers" => [peer | _]}} = Port.find(finder, predicates)
    finder_text = address(finder_address)
    gpu_text = address(gpu_address)

    emit.(
      event("addresses", "discovery", "ok", "addresses: finder=#{finder_text} gpu=#{gpu_text}", %{
        finder: finder_address,
        gpu: gpu_address
      })
    )

    message =
      "selected peer: #{peer["endpoint_id"]} #{peer["node_name"]} at #{peer["partisan_ip"]}:#{peer["partisan_port"]} (signed sequence #{sequence})"

    emit.(
      event("verified", "verified", "ok", "Signed capability record verified", %{
        sequence: sequence
      })
    )

    emit.(event("peer", "partisan", "ok", message, %{peer: peer, sequence: sequence}))

    emit.(
      event(
        "stage",
        "horde",
        "running",
        "STAGE 2: LOCAL HORDE PLACEMENT (not remote BEAM placement)"
      )
    )

    id = "talk-worker-#{System.unique_integer([:positive, :monotonic])}"
    caller = self()

    child = %{
      id: id,
      restart: :temporary,
      start: {Task, :start_link, [fn -> send(caller, {id, {:demo_result, id, node()}}) end]}
    }

    {:ok, _pid} =
      Network.start_child(%{gpu: true}, child,
        discovery: finder,
        authorized_nodes: %{partisan_name => node()}
      )

    receive do
      {^id, {:demo_result, ^id, result_node} = result} ->
        emit.(
          event(
            "result",
            "complete",
            "ok",
            "result: #{inspect(result)} on current Horde member",
            %{
              worker_id: id,
              node: to_string(result_node)
            }
          )
        )
    after
      5_000 -> raise "demo worker timed out"
    end

    :ok
  end

  defp remote_demo(finder, _partisan_name, opts, emit) do
    emit.(
      event(
        "stage",
        "discovery",
        "running",
        "STAGE 1: DISCOVER REMOTE RASPBERRY PI (finder daemon only)"
      )
    )

    {:ok, %{"endpoint_id" => finder_id}} = Port.identity(finder)

    emit.(
      event("identities", "discovery", "ok", "Finder ready; awaiting remote Raspberry Pi", %{
        daemons: %{
          finder: %{endpoint_id: finder_id, status: "active"},
          gpu: %{status: "waiting", role: "remote Raspberry Pi"}
        }
      })
    )

    network_options = %{
      "dns" => true,
      "mdns" => true,
      "dht" => true,
      "relay" => true,
      "bootstrap_endpoint_ids" => Keyword.get(opts, :bootstrap_endpoint_ids, [])
    }

    {:ok, %{"endpoint_address" => finder_address}} = Port.network_start(finder, network_options)

    emit.(
      event("addresses", "discovery", "ok", "finder listening at #{address(finder_address)}", %{
        finder: finder_address
      })
    )

    timeout = Keyword.get(opts, :discovery_timeout, 30_000)
    poll_interval = Keyword.get(opts, :discovery_poll_interval, 500)
    peer = find_remote_gpu(finder, emit, timeout, poll_interval)
    sequence = peer["sequence"]

    emit.(
      event("verified", "verified", "ok", "Remote Raspberry Pi capability record verified", %{
        sequence: sequence
      })
    )

    selected_peer = Map.put(peer, "placement", "remote Raspberry Pi")

    emit.(
      event(
        "peer",
        "partisan",
        "ok",
        "selected remote Raspberry Pi: #{peer["node_name"]} at #{peer["partisan_ip"]}:#{peer["partisan_port"]}",
        %{peer: selected_peer, sequence: sequence}
      )
    )

    emit.(
      event(
        "stage",
        "horde",
        "running",
        "STAGE 2: PARTISAN JOIN AND HORDE HANDOFF TO REMOTE RASPBERRY PI"
      )
    )

    id = "talk-worker-#{System.unique_integer([:positive, :monotonic])}"
    caller = self()

    child = %{
      id: id,
      restart: :temporary,
      start: {Task, :start_link, [fn -> send(caller, {id, {:demo_result, id, node()}}) end]}
    }

    authorized_nodes =
      Keyword.get_lazy(opts, :authorized_nodes, fn ->
        %{peer["node_name"] => String.to_atom(peer["node_name"])}
      end)

    {:ok, _pid} =
      Network.start_child(%{gpu: true}, child,
        discovery: finder,
        authorized_nodes: authorized_nodes,
        timeout: Keyword.get(opts, :handoff_timeout, 5_000)
      )

    receive do
      {^id, {:demo_result, ^id, result_node} = result} ->
        emit.(
          event(
            "result",
            "complete",
            "ok",
            "remote Raspberry Pi result: #{inspect(result)}",
            %{worker_id: id, node: to_string(result_node), peer: selected_peer}
          )
        )
    after
      5_000 -> raise "remote demo worker timed out"
    end

    :ok
  end

  defp find_remote_gpu(finder, emit, timeout, poll_interval) do
    deadline = System.monotonic_time(:millisecond) + timeout
    predicates = [%{"op" => "equals", "name" => "gpu", "value" => true}]
    find_remote_gpu(finder, emit, predicates, deadline, timeout, poll_interval, 1)
  end

  defp find_remote_gpu(finder, emit, predicates, deadline, timeout, poll_interval, attempt) do
    emit.(
      event(
        "discovery_attempt",
        "discovery",
        "running",
        "Looking for remote Raspberry Pi GPU (attempt #{attempt})",
        %{attempt: attempt}
      )
    )

    case Port.find(finder, predicates) do
      {:ok, %{"peers" => [peer | _]}} ->
        peer

      _ ->
        wait_for_remote_gpu(finder, emit, predicates, deadline, timeout, poll_interval, attempt)
    end
  end

  defp wait_for_remote_gpu(finder, emit, predicates, deadline, timeout, poll_interval, attempt) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case remaining > 0 do
      true ->
        Process.sleep(min(poll_interval, remaining))
        find_remote_gpu(finder, emit, predicates, deadline, timeout, poll_interval, attempt + 1)

      false ->
        raise "remote Raspberry Pi GPU discovery timed out after #{timeout}ms"
    end
  end

  defp event(type, stage, status, message, data \\ %{}) do
    %{
      type: type,
      stage: stage,
      status: status,
      message: message,
      at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      data: data
    }
  end

  defp start_runtime do
    case Process.whereis(ElixirRpc.DynamicSupervisor) do
      nil ->
        {:ok, _} = Application.ensure_all_started(:partisan)
        {:ok, _} = Application.ensure_all_started(:horde)

        children = [
          {Horde.Registry,
           name: ElixirRpc.Registry,
           keys: :unique,
           members: {:auto, Horde.NodeListener.Partisan},
           transport: Horde.ClusterTransport.Partisan},
          {Horde.DynamicSupervisor,
           name: ElixirRpc.DynamicSupervisor,
           strategy: :one_for_one,
           members: {:auto, Horde.NodeListener.Partisan},
           distribution_strategy: ElixirRpc.Network.CapabilityDistributionStrategy}
        ]

        {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
        supervisor

      _pid ->
        nil
    end
  end

  defp start_port(executable, data_dir, fleet, node_name) do
    Port.start_link(
      executable: executable,
      data_dir: data_dir,
      fleet_id: fleet,
      node_name: node_name
    )
  end

  defp partisan_endpoint do
    [%{ip: ip, port: port} | _] = :partisan_config.get(:listen_addrs)
    {ip |> :inet.ntoa() |> to_string(), port}
  end

  defp address(%{"direct_addresses" => addresses}), do: Enum.join(addresses, ",")

  defp temporary_root,
    do: Path.join(System.tmp_dir!(), "talk-demo-#{System.unique_integer([:positive])}")

  defp fleet_id, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  defp stop_port(pid), do: if(Process.alive?(pid), do: Port.shutdown(pid))
  defp stop_runtime(nil), do: :ok
  defp stop_runtime(pid), do: if(Process.alive?(pid), do: Supervisor.stop(pid))
end

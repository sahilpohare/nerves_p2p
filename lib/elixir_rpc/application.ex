defmodule ElixirRpc.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      network_children(Application.get_env(:elixir_rpc, :network_mode, :legacy)) ++
        [
          ElixirRpc.Telemetry.Counters,
          {Horde.Registry,
           name: ElixirRpc.Registry,
           keys: :unique,
           members: {:auto, Horde.NodeListener.Partisan},
           transport: Horde.ClusterTransport.Partisan},
          {Horde.DynamicSupervisor,
           name: ElixirRpc.DynamicSupervisor,
           strategy: :one_for_one,
           members: {:auto, Horde.NodeListener.Partisan},
           distribution_strategy: ElixirRpc.Network.CapabilityDistributionStrategy},
          ElixirRpc.Network.ModuleRegistry
        ] ++ target_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixirRpc.Supervisor)
  end

  defp network_children(:legacy) do
    [
      ElixirRpc.P2P.Supervisor,
      {ElixirRpc.P2P.Node, name: ElixirRpc.Node, enable_mdns: true, enable_kademlia: true},
      ElixirRpc.Discovery,
      {ElixirRpc.OTP.Distribution.Server, node: ElixirRpc.Node},
      ElixirRpc.CapabilityRPC.Server,
      ElixirRpc.PeerManager
    ]
  end

  defp network_children(:iroh) do
    [{ElixirRpc.IrohDiscovery.Port, iroh_options()}] ++ talk_worker_children()
  end

  defp talk_worker_children do
    case Application.get_env(:elixir_rpc, :talk_worker, false) do
      true -> [ElixirRpc.TalkWorker]
      opts when is_list(opts) -> talk_worker_children(Keyword.pop(opts, :enabled, true))
      false -> []
    end
  end

  defp talk_worker_children({true, opts}), do: [{ElixirRpc.TalkWorker, opts}]
  defp talk_worker_children({false, _opts}), do: []

  defp iroh_options do
    :elixir_rpc
    |> Application.fetch_env!(:iroh_discovery)
    |> Keyword.put_new(:name, ElixirRpc.IrohDiscovery)
  end

  if Mix.target() == :host do
    defp target_children, do: []
  else
    defp target_children do
      [
        %{
          id: :vintage_net_watcher,
          start: {Task, :start_link, [&watch_network/0]},
          restart: :permanent
        }
      ]
    end

    defp watch_network do
      if Code.ensure_loaded?(VintageNet) do
        VintageNet.subscribe(["interface", :_, "connection"])
        receive_loop()
      end
    end

    defp receive_loop do
      receive do
        {VintageNet, ["interface", _ifname, "connection"], _old, :internet, _meta} ->
          Logger.info("Network up; Iroh discovery will refresh addresses in the background")
          receive_loop()

        _ ->
          receive_loop()
      end
    end
  end
end

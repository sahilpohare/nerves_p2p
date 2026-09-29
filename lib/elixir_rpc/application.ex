defmodule ElixirRpc.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    mode = Application.get_env(:elixir_rpc, :network_mode, :none)
    children = network_children(mode) ++ placement_children(mode)

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixirRpc.Supervisor)
  end

  # :none starts nothing; the consumer supervises what it needs.
  defp placement_children(:none), do: []

  defp placement_children(_mode) do
    [
      ElixirRpc.Telemetry.Counters,
      {Horde.Registry,
       name: ElixirRpc.Registry,
       keys: :unique,
       members: {:auto, ElixirRpc.Horde.PartisanNodeListener},
       transport: ElixirRpc.Horde.PartisanTransport},
      {Horde.DynamicSupervisor,
       name: ElixirRpc.DynamicSupervisor,
       strategy: :one_for_one,
       members: {:auto, ElixirRpc.Horde.PartisanNodeListener},
       distribution_strategy: ElixirRpc.Network.CapabilityDistributionStrategy},
      ElixirRpc.Network.ModuleRegistry
    ]
  end

  defp network_children(:none), do: []

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
end

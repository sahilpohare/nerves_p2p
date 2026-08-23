defmodule ElixirRpc.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      ElixirRpc.P2P.Supervisor,
      ElixirRpc.Telemetry.Counters,
      # Main libp2p node — registered as ElixirRpc.Node for the whole app
      {ElixirRpc.P2P.Node, name: ElixirRpc.Node, enable_mdns: true, enable_kademlia: true},
      # Handles inbound OTP distribution requests from remote peers
      {ElixirRpc.OTP.Distribution.Server, node: ElixirRpc.Node},
      # Handles inbound capability-based RPC apply calls
      ElixirRpc.CapabilityRPC.Server,
      ElixirRpc.PeerManager,
      {Horde.Registry, name: ElixirRpc.Registry, keys: :unique, members: {:auto, Horde.NodeListener.Partisan}, transport: Horde.ClusterTransport.Partisan},
      {Horde.DynamicSupervisor, name: ElixirRpc.DynamicSupervisor, strategy: :one_for_one, members: {:auto, Horde.NodeListener.Partisan}, distribution_strategy: ElixirRpc.Network.CapabilityDistributionStrategy},
      ElixirRpc.Network.ModuleRegistry
    ] ++ target_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixirRpc.Supervisor)
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
          Logger.info("Network up — triggering Partisan mDNS peer discovery")
          :partisan_peer_discovery.discover()
          receive_loop()

        _ ->
          receive_loop()
      end
    end
  end
end

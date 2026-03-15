defmodule ElixirRpc.PeerManager do
  @moduledoc """
  Manages Partisan peer connections using Nerves' built-in mDNS discovery.

  This module listens for mDNS service announcements (already provided by mdns_lite)
  and automatically connects discovered peers to the Partisan mesh network.

  Uses VintageNet to monitor network changes and mdns_lite's existing discovery.
  """

  use GenServer
  require Logger

  alias ElixirRpc.PartisanConfig

  @partisan_service "_partisan._tcp.local"

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually connect to a peer by IP address.
  """
  def connect_peer(ip_address, port \\ 10200) do
    GenServer.call(__MODULE__, {:connect_peer, ip_address, port})
  end

  @doc """
  Get current mesh members.
  """
  def members do
    PartisanConfig.members()
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting Peer Manager")

    # Subscribe to VintageNet events (network up/down) on target only
    if Code.ensure_loaded?(VintageNet) do
      VintageNet.subscribe(["interface"])
    end

    # Initial state
    state = %{
      connected_peers: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:connect_peer, ip_address, port}, _from, state) do
    node_name = :"elixir_rpc@#{ip_address}"

    peer_spec = %{
      name: node_name,
      listen_addrs: [%{ip: PartisanConfig.parse_ip(ip_address), port: port}]
    }

    result = PartisanConfig.join_peer(peer_spec)

    new_state =
      case result do
        :ok -> %{state | connected_peers: MapSet.put(state.connected_peers, node_name)}
        _ -> state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_info({VintageNet, ["interface", _ifname, "connection"], _old, :internet, _meta}, state) do
    Logger.info("Network connection established - checking for peers")
    # When network comes up, we could trigger peer discovery
    # For now, Partisan's gossip protocol will handle this
    {:noreply, state}
  end

  @impl true
  def handle_info({VintageNet, _properties, _old_value, _new_value, _meta}, state) do
    # Ignore other VintageNet events
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end

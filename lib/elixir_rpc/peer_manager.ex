defmodule ElixirRpc.PeerManager do
  @moduledoc """
  Manages Partisan peer connections with automatic mDNS discovery.

  Responsibilities:
  - Periodic auto-discovery of Partisan peers via mDNS
  - Manual peer connections
  - Network event handling (VintageNet integration)
  - Deduplication and tracking of discovered peers
  """

  use GenServer
  require Logger

  alias ElixirRpc.PartisanConfig

  @discovery_interval 15_000

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
  Manually trigger peer discovery scan.
  """
  def discover_now do
    GenServer.cast(__MODULE__, :discover)
  end

  @doc """
  Get current mesh members.
  """
  def members do
    PartisanConfig.members()
  end

  @doc """
  Get discovered peers (not necessarily connected).
  """
  def discovered_peers do
    GenServer.call(__MODULE__, :get_discovered)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting Peer Manager with auto-discovery")

    # Subscribe to VintageNet events (network up/down) on Nerves targets only
    if Mix.target() != :host and Code.ensure_loaded?(VintageNet) do
      apply(VintageNet, :subscribe, [["interface"]])
    end

    # Schedule initial discovery
    Process.send_after(self(), :discover, 2000)

    state = %{
      connected_peers: MapSet.new(),
      discovered_peers: MapSet.new(),
      discovery_timer: nil
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
        :ok ->
          %{state |
            connected_peers: MapSet.put(state.connected_peers, node_name),
            discovered_peers: MapSet.put(state.discovered_peers, node_name)
          }
        _ ->
          state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:get_discovered, _from, state) do
    {:reply, MapSet.to_list(state.discovered_peers), state}
  end

  @impl true
  def handle_cast(:discover, state) do
    send(self(), :discover)
    {:noreply, state}
  end

  @impl true
  def handle_info(:discover, state) do
    Logger.debug("Running peer discovery scan...")

    new_peers = discover_peers()

    newly_found =
      new_peers
      |> MapSet.new(fn {name, _spec} -> name end)
      |> MapSet.difference(state.discovered_peers)

    if MapSet.size(newly_found) > 0 do
      Logger.info("Found #{MapSet.size(newly_found)} new peer(s)")

      Enum.each(new_peers, fn {name, spec} ->
        if MapSet.member?(newly_found, name) and not PartisanConfig.connected?(name) do
          Logger.info("Auto-joining peer: #{inspect(name)}")
          PartisanConfig.join_peer(spec)
        end
      end)
    end

    updated_discovered =
      new_peers
      |> Enum.map(fn {name, _spec} -> name end)
      |> MapSet.new()
      |> MapSet.union(state.discovered_peers)

    discovery_timer = Process.send_after(self(), :discover, @discovery_interval)

    {:noreply, %{state | discovered_peers: updated_discovered, discovery_timer: discovery_timer}}
  end

  @impl true
  def handle_info({VintageNet, ["interface", _ifname, "connection"], _old, :internet, _meta}, state) do
    Logger.info("Network connection established - triggering peer discovery")
    send(self(), :discover)
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

  ## Private Functions

  defp discover_peers do
    if Mix.target() == :host do
      # Host mode: no automatic discovery (can still use connect_peer/2)
      []
    else
      # Target mode: use NervesDiscovery
      discover_via_nerves()
    end
  end

  defp discover_via_nerves do
    if Code.ensure_loaded?(NervesDiscovery) do
      case NervesDiscovery.discover(timeout: 3000) do
        devices when is_list(devices) ->
          parse_devices(devices)

        {:error, reason} ->
          Logger.debug("Discovery error: #{inspect(reason)}")
          []
      end
    else
      []
    end
  end

  defp parse_devices(devices) do
    Enum.flat_map(devices, fn
      %{addresses: addresses} when is_list(addresses) ->
        Enum.map(addresses, fn address ->
          name = :"elixir_rpc@#{format_ip(address)}"
          spec = %{name: name, listen_addrs: [%{ip: address, port: 10200}]}
          {name, spec}
        end)

      _device ->
        []
    end)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end

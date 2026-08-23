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

  alias ElixirRpc.{P2P.Discovery, PartisanConfig}

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

    # Subscribe to peer_discovered events from the libp2p node
    Discovery.register_handler(ElixirRpc.Node, self())

    # Subscribe to VintageNet events (network up/down) on Nerves targets only
    if Mix.target() != :host and Code.ensure_loaded?(VintageNet) do
      apply(VintageNet, :subscribe, [["interface"]])
    end

    # Schedule initial Partisan discovery scan
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
          %{
            state
            | connected_peers: MapSet.put(state.connected_peers, node_name),
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
    Logger.debug("Running Partisan peer discovery scan...")
    # Trigger Partisan's own mDNS-based discovery (works on target).
    # libp2p peer discovery flows in via {:libp2p, :peer_discovered, event} messages.
    if function_exported?(:partisan_peer_discovery, :discover, 0) do
      :partisan_peer_discovery.discover()
    end

    discovery_timer = Process.send_after(self(), :discover, @discovery_interval)
    {:noreply, %{state | discovery_timer: discovery_timer}}
  end

  @impl true
  def handle_info(
        {:libp2p, :peer_discovered, %ElixirRpc.P2P.Node.Event.PeerDiscovered{} = event},
        state
      ) do
    # A new peer was discovered via mDNS/DHT. Try to connect it to Partisan.
    peer_id_str = ElixirRpc.PeerId.to_string(event.peer_id)

    Enum.each(event.addresses, fn multiaddr ->
      case parse_partisan_addr(peer_id_str, multiaddr) do
        {:ok, name, spec} ->
          unless PartisanConfig.connected?(name) do
            Logger.info("Auto-joining libp2p-discovered peer: #{inspect(name)}")
            PartisanConfig.join_peer(spec)
          end

        _ ->
          :ok
      end
    end)

    new_discovered = MapSet.put(state.discovered_peers, :"#{peer_id_str}")
    {:noreply, %{state | discovered_peers: new_discovered}}
  end

  @impl true
  def handle_info(
        {VintageNet, ["interface", _ifname, "connection"], _old, :internet, _meta},
        state
      ) do
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

  # Parse a libp2p multiaddr into a Partisan peer spec.
  # Expects multiaddr format: /ip4/<ip>/tcp/<port>
  defp parse_partisan_addr(peer_id, multiaddr) do
    case String.split(multiaddr, "/", trim: true) do
      ["ip4", ip_str, "tcp", port_str] ->
        with {port, ""} <- Integer.parse(port_str),
             {:ok, ip} <- parse_ip(ip_str) do
          name = :"#{peer_id}@#{ip_str}"
          spec = %{name: name, listen_addrs: [%{ip: ip, port: port}]}
          {:ok, name, spec}
        end

      _ ->
        {:error, :unsupported_multiaddr}
    end
  end

  defp parse_ip(ip_str) do
    case ip_str |> String.split(".") |> Enum.map(&Integer.parse/1) do
      [{a, ""}, {b, ""}, {c, ""}, {d, ""}] -> {:ok, {a, b, c, d}}
      _ -> {:error, :invalid_ip}
    end
  end
end

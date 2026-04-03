defmodule ElixirRpc.Libp2pBridge do
  @moduledoc """
  Manages the Rust libp2p bridge process via an Erlang Port.

  This GenServer:
  - Spawns the p2p_bridge Rust binary as an external process
  - Communicates via JSON over stdin/stdout
  - Handles peer discovery, NAT traversal, and connection management
  - Provides STUN/relay information to Partisan

  The Port approach is safe for embedded devices (no NIFs that can crash BEAM).
  """

  use GenServer
  require Logger

  @binary_name "p2p_bridge"
  @command_timeout 5000

  defmodule State do
    @moduledoc false
    defstruct [
      :port,
      :peer_id,
      :listen_addrs,
      :connected_peers,
      :discovered_peers,
      :nat_status,
      pending_commands: %{},
      # Pending callers for query_peers, keyed by query_ref string
      pending_queries: %{}
    ]
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the local libp2p PeerID.
  """
  def get_peer_id do
    GenServer.call(__MODULE__, :get_peer_id, @command_timeout)
  end

  @doc """
  Get current listen addresses (with actual ports assigned by OS).
  """
  def get_listen_addrs do
    GenServer.call(__MODULE__, :get_listen_addrs, @command_timeout)
  end

  @doc """
  Dial a peer by multiaddr.
  """
  def dial(multiaddr) do
    GenServer.call(__MODULE__, {:dial, multiaddr}, @command_timeout)
  end

  @doc """
  Get list of currently connected peers.
  """
  def get_connected_peers do
    GenServer.call(__MODULE__, :get_connected_peers, @command_timeout)
  end

  @doc """
  Get list of discovered peers (not necessarily connected).
  """
  def get_discovered_peers do
    GenServer.call(__MODULE__, :get_discovered_peers)
  end

  @doc """
  Get NAT status (public/private/unknown).
  """
  def get_nat_status do
    GenServer.call(__MODULE__, :get_nat_status)
  end

  @doc """
  Advertise capabilities to the DHT.
  Capabilities should be a list of {name, value} tuples, e.g. [{"camera", nil}, {"gpu", 8}].
  """
  def advertise_capabilities(capabilities) when is_list(capabilities) do
    GenServer.call(__MODULE__, {:advertise, capabilities}, @command_timeout)
  end

  @doc """
  Query the DHT for peers with specific capabilities.
  Returns a list of peer IDs that match the query.
  """
  def query_peers(capabilities, limit \\ 10) when is_list(capabilities) do
    GenServer.call(__MODULE__, {:query_peers, capabilities, limit}, @command_timeout)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting libp2p bridge process")

    # Find the Rust binary
    binary_path = find_binary()

    # Spawn the Port process
    port =
      Port.open({:spawn_executable, binary_path}, [
        {:args, []},
        # 1MB line buffer for JSON
        {:line, 1024 * 1024},
        :binary,
        :exit_status,
        :use_stdio
        # Don't redirect stderr to stdout - let Rust logs go to stderr
        # Only stdout is used for JSON protocol communication
      ])

    state = %State{
      port: port,
      peer_id: nil,
      listen_addrs: [],
      connected_peers: MapSet.new(),
      discovered_peers: MapSet.new(),
      nat_status: :unknown
    }

    # Request initial peer ID
    send(self(), :init_peer_id)

    {:ok, state}
  end

  @impl true
  def handle_info(:init_peer_id, state) do
    send_command(state.port, %{type: "get_peer_id"})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, event} ->
        handle_event(event, state)

      {:error, reason} ->
        Logger.warning("Failed to decode event: #{inspect(reason)}, line: #{line}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("libp2p bridge process exited with status #{status}")
    {:stop, {:port_exit, status}, state}
  end

  @impl true
  def handle_call(:get_peer_id, _from, state) do
    {:reply, state.peer_id, state}
  end

  @impl true
  def handle_call(:get_listen_addrs, from, state) do
    send_command(state.port, %{type: "get_listen_addrs"})

    {:noreply,
     %{state | pending_commands: enqueue_command(state.pending_commands, :listen_addrs, from)}}
  end

  @impl true
  def handle_call({:dial, multiaddr}, _from, state) do
    send_command(state.port, %{type: "dial", multiaddr: multiaddr})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_connected_peers, from, state) do
    send_command(state.port, %{type: "get_connected_peers"})

    {:noreply,
     %{state | pending_commands: enqueue_command(state.pending_commands, :connected_peers, from)}}
  end

  @impl true
  def handle_call(:get_discovered_peers, _from, state) do
    {:reply, MapSet.to_list(state.discovered_peers), state}
  end

  @impl true
  def handle_call(:get_nat_status, _from, state) do
    {:reply, state.nat_status, state}
  end

  @impl true
  def handle_call({:advertise, capabilities}, _from, state) do
    send_command(state.port, %{type: "advertise", capabilities: capabilities})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:query_peers, capabilities, limit}, from, state) do
    # Generate a unique ref so we can match the async peers_found response back to this caller.
    # Rust echoes this token in the query_ref field of the peers_found event.
    query_ref = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    send_command(state.port, %{
      type: "query_peers",
      capabilities: capabilities,
      limit: limit,
      query_ref: query_ref
    })

    {:noreply, %{state | pending_queries: Map.put(state.pending_queries, query_ref, from)}}
  end

  ## Private Functions

  defp find_binary do
    # Look for compiled binary
    binary_name = @binary_name

    possible_paths = [
      # Priv directory (for Nerves releases and mix releases)
      Path.join([:code.priv_dir(:elixir_rpc), binary_name]),
      # Release build (development)
      Path.join([File.cwd!(), "native", "p2p_bridge", "target", "release", binary_name]),
      # Debug build (development)
      Path.join([File.cwd!(), "native", "p2p_bridge", "target", "debug", binary_name])
    ]

    Enum.find(possible_paths, fn path ->
      File.exists?(path)
    end) ||
      raise "Could not find #{binary_name} binary. Run: mix compile or cd native/p2p_bridge && cargo build"
  end

  defp send_command(port, command) do
    json = Jason.encode!(command)
    Port.command(port, [json, ?\n])
  end

  defp handle_event(%{"type" => "peer_id", "peer_id" => peer_id}, state) do
    Logger.info("libp2p PeerID: #{peer_id}")
    {:noreply, %{state | peer_id: peer_id}}
  end

  defp handle_event(%{"type" => "listen_addrs", "addrs" => addrs}, state) do
    Logger.info("Listening on: #{inspect(addrs)}")
    state = dequeue_and_reply(state, :listen_addrs, addrs)
    {:noreply, %{state | listen_addrs: addrs}}
  end

  defp handle_event(%{"type" => "connected_peers", "peers" => peers}, state) do
    state = dequeue_and_reply(state, :connected_peers, peers)
    {:noreply, %{state | connected_peers: MapSet.new(peers)}}
  end

  defp handle_event(%{"type" => "listening_on", "multiaddr" => multiaddr}, state) do
    Logger.info("Now listening on: #{multiaddr}")
    {:noreply, %{state | listen_addrs: [multiaddr | state.listen_addrs]}}
  end

  defp handle_event(
         %{
           "type" => "peer_discovered",
           "peer_id" => peer_id,
           "multiaddr" => multiaddr,
           "protocol" => protocol
         },
         state
       ) do
    Logger.info("Discovered peer via #{protocol}: #{peer_id} at #{multiaddr}")

    discovered = %{peer_id: peer_id, multiaddr: multiaddr, protocol: protocol}
    {:noreply, %{state | discovered_peers: MapSet.put(state.discovered_peers, discovered)}}
  end

  defp handle_event(%{"type" => "nat_status", "status" => status}, state) do
    Logger.info("NAT status: #{status}")
    {:noreply, %{state | nat_status: parse_nat_status(status)}}
  end

  defp handle_event(%{"type" => "upnp_mapped", "external_addr" => addr}, state) do
    Logger.info("UPnP mapped external address: #{addr}")
    {:noreply, state}
  end

  defp handle_event(
         %{"type" => "connection_established", "peer_id" => peer_id, "multiaddr" => multiaddr},
         state
       ) do
    Logger.info("Connected to peer: #{peer_id} at #{multiaddr}")
    {:noreply, %{state | connected_peers: MapSet.put(state.connected_peers, peer_id)}}
  end

  defp handle_event(%{"type" => "connection_closed", "peer_id" => peer_id}, state) do
    Logger.info("Disconnected from peer: #{peer_id}")
    {:noreply, %{state | connected_peers: MapSet.delete(state.connected_peers, peer_id)}}
  end

  defp handle_event(%{"type" => "dialing_peer", "multiaddr" => multiaddr}, state) do
    Logger.debug("Dialing peer: #{multiaddr}")
    {:noreply, state}
  end

  defp handle_event(%{"type" => "pong"}, state) do
    Logger.debug("Received pong")
    {:noreply, state}
  end

  defp handle_event(%{"type" => "advertising", "capabilities" => capabilities}, state) do
    Logger.info("Successfully advertised capabilities to DHT: #{inspect(capabilities)}")
    {:noreply, state}
  end

  # peers_found with a query_ref — reply to the waiting caller
  defp handle_event(%{"type" => "peers_found", "query_ref" => query_ref, "peers" => peers}, state)
       when is_binary(query_ref) do
    Logger.info("DHT query (ref=#{query_ref}) returned #{length(peers)} peers")

    state =
      case Map.pop(state.pending_queries, query_ref) do
        {nil, queries} ->
          Logger.warning("Received peers_found for unknown query_ref: #{query_ref}")
          %{state | pending_queries: queries}

        {from, queries} ->
          GenServer.reply(from, {:ok, peers})
          %{state | pending_queries: queries}
      end

    {:noreply, state}
  end

  # peers_found without a query_ref — unsolicited DHT result (routing maintenance etc.)
  defp handle_event(%{"type" => "peers_found", "peers" => peers}, state) do
    Logger.debug("Unsolicited DHT peers_found: #{length(peers)} peers (routing maintenance)")
    {:noreply, state}
  end

  defp handle_event(%{"type" => "error", "message" => message}, state) do
    Logger.error("libp2p error: #{message}")
    {:noreply, state}
  end

  defp handle_event(event, state) do
    Logger.warning("Unknown event: #{inspect(event)}")
    {:noreply, state}
  end

  defp parse_nat_status("public:" <> _addr), do: :public
  defp parse_nat_status("private"), do: :private
  defp parse_nat_status("unknown"), do: :unknown
  defp parse_nat_status(_), do: :unknown

  defp enqueue_command(pending, key, from) do
    Map.update(pending, key, [from], &(&1 ++ [from]))
  end

  defp dequeue_and_reply(state, key, reply) do
    case Map.get(state.pending_commands, key, []) do
      [] ->
        state

      [from | rest] ->
        GenServer.reply(from, reply)
        %{state | pending_commands: Map.put(state.pending_commands, key, rest)}
    end
  end
end

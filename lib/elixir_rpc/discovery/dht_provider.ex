defmodule ElixirRpc.Discovery.DhtProvider do
  @moduledoc """
  Kademlia DHT-based peer discovery provider.

  This provider uses libp2p's Kademlia DHT for distributed peer and capability discovery.
  It's slower than mDNS but works globally across the mesh, even beyond NATs.

  ## Characteristics

  - **Scope**: Global (entire P2P network)
  - **Speed**: Slower (seconds for lookups)
  - **Persistence**: High (replicated across nodes)
  - **NAT Traversal**: Yes (via libp2p relay)

  ## How It Works

  1. Peer info and capabilities are stored in the DHT using libp2p
  2. Keys use namespaced format: "peer:<peer_id>", "capability:<name>"
  3. Data is replicated across multiple DHT nodes
  4. Lookups query the DHT and cache results locally

  ## Key Schema

  - `peer:<peer_id>` → Full peer information (addresses, capabilities, metadata)
  - `capability:<capability_name>` → List of peer IDs with this capability
  - `node:<node_name>` → Peer ID for node name resolution

  ## Integration with libp2p

  This provider sends commands to the Rust libp2p bridge:
  - `Advertise` - Store capabilities in DHT
  - `QueryPeers` - Find peers with capabilities
  """

  @behaviour ElixirRpc.Discovery.Provider

  require Logger
  alias ElixirRpc.Discovery.PeerInfo
  alias ElixirRpc.DHT
  alias ElixirRpc.P2P.Node.Event.DHTQueryResult

  # Key prefix used for DHT capability records
  @capability_prefix "cap:"

  defmodule State do
    @moduledoc false
    defstruct [
      # GenServer name/pid of the P2P.Node to use
      :node,
      # Map of peer_id => PeerInfo
      :cached_peers,
      # Map of capability => [peer_id]
      :cached_capabilities,
      :pending_capabilities,
      :last_publish
    ]
  end

  @impl true
  def init(opts) do
    Logger.debug("Initializing DHT discovery provider")
    node = Keyword.get(opts, :node, ElixirRpc.Node)
    :ok = DHT.register_handler(node)

    state = %State{
      node: node,
      cached_peers: %{},
      cached_capabilities: %{},
      pending_capabilities: [],
      last_publish: nil
    }

    {:ok, state}
  end

  @impl true
  def advertise_self(state, peer_info) do
    # Advertise each capability as a DHT provider record.
    # Key: "cap:<capability_name>" — peers looking for this capability do find_providers on it.
    results =
      Enum.map(peer_info.capabilities, fn cap ->
        key = @capability_prefix <> to_string(cap)
        DHT.provide(state.node, key)
      end)

    if Enum.all?(results, &(&1 == :ok)) do
      Logger.debug("Advertised #{length(peer_info.capabilities)} capabilities to DHT")
      {:ok, %{state | last_publish: System.monotonic_time(:millisecond)}}
    else
      Logger.warning("Some DHT capability advertisements failed")
      {:ok, %{state | last_publish: System.monotonic_time(:millisecond)}}
    end
  end

  @impl true
  def advertise_capability(state, capability, _metadata) do
    key = @capability_prefix <> to_string(capability)

    case DHT.provide(state.node, key) do
      :ok ->
        Logger.debug("Advertised capability #{capability} to DHT")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Failed to advertise capability #{capability} to DHT: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def find_capability(state, capability) do
    # Check cache first
    cached_peers = Map.get(state.cached_capabilities, capability, [])

    fresh_cached =
      cached_peers
      |> Enum.map(&Map.get(state.cached_peers, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&PeerInfo.stale?(&1, 600))

    if Enum.any?(fresh_cached) do
      {:ok, fresh_cached, state}
    else
      # Issue async DHT find_providers. Results arrive as dht_query_result events
      # to registered handlers. For synchronous calls the coordinator falls back
      # to empty list — callers should subscribe to events for live updates.
      key = @capability_prefix <> to_string(capability)

      case DHT.find_providers(state.node, key) do
        :ok ->
          {:ok, fresh_cached,
           %{state | pending_capabilities: state.pending_capabilities ++ [capability]}}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  @impl true
  def handle_event(
        %{pending_capabilities: [capability | pending]} = state,
        %DHTQueryResult{result: {:found_providers, peer_ids}}
      ) do
    peers =
      Map.new(peer_ids, fn peer_id ->
        {peer_id,
         %PeerInfo{
           peer_id: peer_id,
           capabilities: [capability],
           last_seen: DateTime.utc_now(),
           discovery_source: :dht
         }}
      end)

    {:ok,
     %{
       state
       | cached_peers: Map.merge(state.cached_peers, peers),
         cached_capabilities: Map.put(state.cached_capabilities, capability, peer_ids),
         pending_capabilities: pending
     }}
  end

  def handle_event(state, _event), do: {:ok, state}

  @impl true
  def find_peer(state, node_name) do
    # Try to find peer in cache by node name
    cached_peer =
      state.cached_peers
      |> Map.values()
      |> Enum.find(fn peer -> peer.node == node_name end)

    case cached_peer do
      nil ->
        # TODO: Query DHT with key "node:<node_name>"
        # For now, return not found
        {:error, :not_found, state}

      peer ->
        {:ok, peer, state}
    end
  end

  @impl true
  def get_discovered_peers(state) do
    peers =
      state.cached_peers
      |> Map.values()
      |> Enum.reject(&PeerInfo.stale?(&1, 600))

    {peers, state}
  end
end

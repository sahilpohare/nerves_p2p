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

  defmodule State do
    @moduledoc false
    defstruct [
      :cached_peers,      # Map of peer_id => PeerInfo
      :cached_capabilities, # Map of capability => [peer_id]
      :last_publish
    ]
  end

  @impl true
  def init(_opts) do
    Logger.debug("Initializing DHT discovery provider")

    state = %State{
      cached_peers: %{},
      cached_capabilities: %{},
      last_publish: nil
    }

    # TODO: Send DHT bootstrap command to libp2p
    # For now, DHT bootstraps automatically

    {:ok, state}
  end

  @impl true
  def advertise_self(state, peer_info) do
    # Build capabilities map for libp2p
    capabilities_map =
      Enum.reduce(peer_info.capabilities, %{}, fn cap, acc ->
        Map.put(acc, to_string(cap), peer_info.metadata[cap] || %{})
      end)

    # Send advertise command to libp2p bridge
    # This will store our capabilities in the DHT
    case send_advertise_command(capabilities_map) do
      :ok ->
        Logger.debug("Advertised self to DHT: #{inspect(capabilities_map)}")
        {:ok, %{state | last_publish: System.monotonic_time(:millisecond)}}

      {:error, reason} ->
        Logger.warning("Failed to advertise self to DHT: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def advertise_capability(state, capability, metadata) do
    # Advertise a single capability
    capabilities_map = %{to_string(capability) => metadata}

    case send_advertise_command(capabilities_map) do
      :ok ->
        Logger.debug("Advertised capability #{capability} to DHT")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Failed to advertise capability to DHT: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def find_capability(state, capability) do
    # Check cache first
    cached_peers = Map.get(state.cached_capabilities, capability, [])

    if Enum.any?(cached_peers) do
      # Return cached results
      peers =
        cached_peers
        |> Enum.map(&Map.get(state.cached_peers, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&PeerInfo.stale?(&1, 600))

      {:ok, peers, state}
    else
      # Query DHT
      case query_dht_for_capability(capability) do
        {:ok, peers} ->
          # Update cache
          peer_ids = Enum.map(peers, & &1.peer_id)
          new_cached_caps = Map.put(state.cached_capabilities, capability, peer_ids)

          new_cached_peers =
            Enum.reduce(peers, state.cached_peers, fn peer, acc ->
              Map.put(acc, peer.peer_id, peer)
            end)

          new_state = %{state |
            cached_capabilities: new_cached_caps,
            cached_peers: new_cached_peers
          }

          {:ok, peers, new_state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

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

  ## Private Functions

  defp send_advertise_command(capabilities_map) do
    command = %{type: "advertise", capabilities: capabilities_map}

    case Jason.encode(command) do
      {:ok, json} ->
        Logger.debug("DHT advertise command (needs LibP2pBridge integration): #{json}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_dht_for_capability(capability) do
    command = %{
      type: "query_peers",
      capabilities: [%{to_string(capability) => %{}}],
      limit: 10
    }

    case Jason.encode(command) do
      {:ok, json} ->
        Logger.debug("DHT query command (needs Libp2pBridge integration): #{json}")
        # TODO: Implement actual DHT query via Libp2pBridge
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

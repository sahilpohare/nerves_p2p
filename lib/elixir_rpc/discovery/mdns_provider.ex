defmodule ElixirRpc.Discovery.MdnsProvider do
  @moduledoc """
  mDNS-based peer discovery provider.

  This provider uses libp2p's mDNS implementation for local network discovery.
  It's fast and works without any infrastructure, but is limited to the local network.

  ## Characteristics

  - **Scope**: Local network only (broadcast domain)
  - **Speed**: Very fast (milliseconds)
  - **Persistence**: None (ephemeral)
  - **NAT Traversal**: Not applicable (local only)

  ## How It Works

  1. libp2p's mDNS automatically discovers peers on the local network
  2. This provider subscribes to libp2p peer discovery events
  3. Discovered peers are cached locally with TTL
  4. Capabilities are stored locally (no distribution)

  ## Limitations

  - Cannot discover peers outside local network
  - No capability advertisement beyond local network
  - Requires multicast support on network
  """

  @behaviour ElixirRpc.Discovery.Provider

  require Logger
  alias ElixirRpc.Discovery.PeerInfo
  alias ElixirRpc.Libp2pBridge

  defmodule State do
    @moduledoc false
    defstruct [
      :discovered_peers,  # Map of peer_id => PeerInfo
      :last_scan
    ]
  end

  @impl true
  def init(_opts) do
    Logger.debug("Initializing mDNS discovery provider")

    state = %State{
      discovered_peers: %{},
      last_scan: nil
    }

    {:ok, state}
  end

  @impl true
  def advertise_self(state, _peer_info) do
    # mDNS advertisement is handled automatically by libp2p
    # No explicit action needed - libp2p broadcasts presence
    {:ok, state}
  end

  @impl true
  def advertise_capability(state, _capability, _metadata) do
    # Capabilities via mDNS would require custom TXT records
    # For now, capabilities are only stored locally
    # DHT provider should be used for distributed capability advertisement
    {:ok, state}
  end

  @impl true
  def find_capability(state, capability) do
    # Search local cache for peers with capability
    peers =
      state.discovered_peers
      |> Map.values()
      |> Enum.filter(&PeerInfo.has_capability?(&1, capability))
      |> Enum.reject(&PeerInfo.stale?(&1, 120))

    {:ok, peers, state}
  end

  @impl true
  def find_peer(state, node_name) do
    # Search local cache by node name
    result =
      state.discovered_peers
      |> Map.values()
      |> Enum.find(fn peer -> peer.node == node_name end)

    case result do
      nil -> {:error, :not_found, state}
      peer -> {:ok, peer, state}
    end
  end

  @impl true
  def get_discovered_peers(state) do
    peers =
      state.discovered_peers
      |> Map.values()
      |> Enum.reject(&PeerInfo.stale?(&1, 120))

    {peers, state}
  end

  @impl true
  def scan(state) do
    # Query libp2p for currently discovered peers
    case Libp2pBridge.get_discovered_peers() do
      discovered when is_list(discovered) ->
        # Update our cache with libp2p's discovered peers
        new_peers =
          Enum.reduce(discovered, state.discovered_peers, fn discovered_peer, acc ->
            case peer_info_from_libp2p(discovered_peer) do
              %PeerInfo{} = peer_info -> Map.put(acc, peer_info.peer_id, peer_info)
              :error -> acc
            end
          end)

        new_state = %{state | discovered_peers: new_peers, last_scan: System.monotonic_time(:millisecond)}
        {:ok, new_state}

      _error ->
        {:error, :scan_failed}
    end
  end

  ## Private Functions

  defp peer_info_from_libp2p(%{peer_id: peer_id, multiaddr: multiaddr, protocol: protocol}) do
    %PeerInfo{
      peer_id: peer_id,
      node: nil,
      listen_addrs: [multiaddr],
      capabilities: [],
      metadata: %{protocol: protocol},
      last_seen: DateTime.utc_now(),
      discovery_source: :mdns
    }
  end

  defp peer_info_from_libp2p(_), do: :error
end

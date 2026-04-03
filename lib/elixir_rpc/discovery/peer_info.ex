defmodule ElixirRpc.Discovery.PeerInfo do
  @moduledoc """
  Peer information structure used across all discovery providers.

  This struct provides a unified representation of peer metadata,
  making it easy to work with peers discovered via different mechanisms
  (mDNS, DHT, gossip, etc.).

  ## Protocol Implementation

  Implements the `String.Chars` protocol for easy debugging and logging.
  """

  @type t :: %__MODULE__{
          peer_id: String.t() | nil,
          node: atom() | nil,
          listen_addrs: list(String.t()),
          capabilities: list(atom()),
          metadata: map(),
          last_seen: DateTime.t(),
          discovery_source: atom()
        }

  defstruct [
    :peer_id,
    :node,
    listen_addrs: [],
    capabilities: [],
    metadata: %{},
    last_seen: nil,
    discovery_source: :unknown
  ]

  @doc """
  Create a new PeerInfo struct with validation.
  """
  def new(attrs \\ %{}) do
    struct!(__MODULE__, Map.put_new(attrs, :last_seen, DateTime.utc_now()))
  end

  @doc """
  Check if peer info is stale (older than TTL).
  """
  def stale?(%__MODULE__{last_seen: last_seen}, ttl_seconds \\ 300) do
    case last_seen do
      nil -> true
      dt -> DateTime.diff(DateTime.utc_now(), dt, :second) > ttl_seconds
    end
  end

  @doc """
  Check if peer has a specific capability.
  """
  def has_capability?(%__MODULE__{capabilities: capabilities}, capability) do
    capability in capabilities
  end

  @doc """
  Update the last_seen timestamp to now.
  """
  def touch(%__MODULE__{} = peer_info) do
    %{peer_info | last_seen: DateTime.utc_now()}
  end
end

defimpl String.Chars, for: ElixirRpc.Discovery.PeerInfo do
  def to_string(peer) do
    "PeerInfo<#{peer.peer_id || "no-id"}, #{peer.node || "no-node"}, caps: #{inspect(peer.capabilities)}>"
  end
end

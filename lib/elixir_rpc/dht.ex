defmodule ElixirRpc.DHT do
  @moduledoc """
  Kademlia DHT operations for distributed storage and peer discovery.

  All operations are asynchronous. Results arrive as events to registered handlers.

  ## Usage

      :ok = ElixirRpc.DHT.register_handler(node)
      :ok = ElixirRpc.DHT.put_record(node, "my-key", "my-value")
      :ok = ElixirRpc.DHT.get_record(node, "my-key")

      # Results arrive as:
      # {:libp2p, :dht_query_result, %ElixirRpc.P2P.Node.Event.DHTQueryResult{}}

  """

  alias ElixirRpc.{P2P.Node, PeerId}

  import ElixirRpc.Call, only: [safe_call: 2]

  @spec put_record(GenServer.server(), binary(), binary()) :: :ok | {:error, term()}
  def put_record(node, key, value) when is_binary(key) and is_binary(value) do
    safe_call(node, {:dht_put, key, value})
  end

  @spec get_record(GenServer.server(), binary()) :: :ok | {:error, term()}
  def get_record(node, key) when is_binary(key) do
    safe_call(node, {:dht_get, key})
  end

  @spec find_peer(GenServer.server(), PeerId.t()) :: :ok | {:error, term()}
  def find_peer(node, %PeerId{id: peer_id_str}) do
    safe_call(node, {:dht_find_peer, peer_id_str})
  end

  @spec provide(GenServer.server(), binary()) :: :ok | {:error, term()}
  def provide(node, key) when is_binary(key) do
    safe_call(node, {:dht_provide, key})
  end

  @spec find_providers(GenServer.server(), binary()) :: :ok | {:error, term()}
  def find_providers(node, key) when is_binary(key) do
    safe_call(node, {:dht_find_providers, key})
  end

  @spec bootstrap(GenServer.server()) :: :ok | {:error, term()}
  def bootstrap(node), do: safe_call(node, :dht_bootstrap)

  @spec register_handler(GenServer.server(), pid()) :: :ok
  def register_handler(node, pid \\ self()),
    do: Node.register_handler(node, :dht_query_result, pid)
end

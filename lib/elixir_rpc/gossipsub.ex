defmodule ElixirRpc.Gossipsub do
  @moduledoc """
  GossipSub publish-subscribe messaging.

  ## Usage

      :ok = ElixirRpc.Gossipsub.subscribe(node, "my-topic")
      :ok = ElixirRpc.Gossipsub.register_handler(node)
      :ok = ElixirRpc.Gossipsub.publish(node, "my-topic", "hello world")

      # Receive in handle_info:
      # {:libp2p, :gossipsub_message, %ElixirRpc.P2P.Node.Event.GossipsubMessage{}}

  """

  alias ElixirRpc.{P2P.Node, PeerId}
  alias ElixirRpc.P2P.Node.Result

  import ElixirRpc.Call, only: [safe_call: 2]

  @spec subscribe(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def subscribe(node, topic) when is_binary(topic) do
    result = safe_call(node, {:subscribe, topic})

    :telemetry.execute(
      [:elixir_rpc, :gossipsub, :subscribe],
      %{count: 1},
      %{topic: topic, result: Result.tag(result)}
    )

    result
  end

  @spec unsubscribe(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(node, topic) when is_binary(topic) do
    result = safe_call(node, {:unsubscribe, topic})

    :telemetry.execute(
      [:elixir_rpc, :gossipsub, :unsubscribe],
      %{count: 1},
      %{topic: topic, result: Result.tag(result)}
    )

    result
  end

  @spec publish(GenServer.server(), String.t(), binary()) :: :ok | {:error, term()}
  def publish(node, topic, data) when is_binary(topic) and is_binary(data) do
    :telemetry.span(
      [:elixir_rpc, :gossipsub, :publish],
      %{topic: topic, size: byte_size(data)},
      fn ->
        result = safe_call(node, {:publish, topic, data})
        {result, %{result: Result.tag(result)}}
      end
    )
  end

  @spec register_handler(GenServer.server(), pid()) :: :ok
  def register_handler(node, pid \\ self()) do
    Node.register_handler(node, :gossipsub_message, pid)
  end

  @spec mesh_peers(GenServer.server(), String.t()) :: {:ok, [PeerId.t()]} | {:error, term()}
  def mesh_peers(node, topic) when is_binary(topic) do
    case safe_call(node, {:gossipsub_mesh_peers, topic}) do
      {:ok, peers} -> {:ok, Enum.map(peers, &PeerId.new!/1)}
      {:error, _} = error -> error
    end
  end

  @spec all_peers(GenServer.server()) :: {:ok, [PeerId.t()]} | {:error, term()}
  def all_peers(node) do
    case safe_call(node, :gossipsub_all_peers) do
      {:ok, peers} -> {:ok, Enum.map(peers, &PeerId.new!/1)}
      {:error, _} = error -> error
    end
  end

  @spec peer_score(GenServer.server(), PeerId.t()) :: {:ok, float()} | {:error, term()}
  def peer_score(node, %PeerId{id: peer_id_str}) do
    safe_call(node, {:gossipsub_peer_score, peer_id_str})
  end
end

defmodule ElixirRpc.RequestResponse do
  @moduledoc """
  Request-response RPC protocol.

  Provides point-to-point request/response communication between peers.

  ## Usage

      :ok = ElixirRpc.RequestResponse.register_handler(node)
      {:ok, request_id} = ElixirRpc.RequestResponse.send_request(node, peer_id, payload)

      # Handle inbound requests in handle_info:
      # {:libp2p, :inbound_request, %ElixirRpc.P2P.Node.Event.InboundRequest{}}

      :ok = ElixirRpc.RequestResponse.send_response(node, channel_id, response_data)

  """

  alias ElixirRpc.{P2P.Node, PeerId}

  import ElixirRpc.Call, only: [safe_call: 2]

  @spec send_request(GenServer.server(), PeerId.t(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def send_request(node, %PeerId{id: peer_id_str}, data) when is_binary(data) do
    safe_call(node, {:rpc_send_request, peer_id_str, data})
  end

  @spec send_response(GenServer.server(), String.t(), binary()) :: :ok | {:error, term()}
  def send_response(node, channel_id, data) when is_binary(channel_id) and is_binary(data) do
    safe_call(node, {:rpc_send_response, channel_id, data})
  end

  @spec register_handler(GenServer.server(), pid()) :: :ok
  def register_handler(node, pid \\ self()) do
    :ok = Node.register_handler(node, :inbound_request, pid)
    Node.register_handler(node, :outbound_response, pid)
  end
end

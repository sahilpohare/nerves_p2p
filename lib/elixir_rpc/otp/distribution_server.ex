defmodule ElixirRpc.OTP.Distribution.Server do
  @moduledoc """
  Handles inbound OTP distribution requests from remote peers.

  Listens for request-response inbound requests, deserializes them,
  dispatches to locally registered GenServers, and sends back the reply.

  ## Usage

  Add to your supervision tree:

      children = [
        {ElixirRpc.P2P.Node, listen_addrs: ["/ip4/0.0.0.0/tcp/0"]},
        {ElixirRpc.OTP.Distribution.Server, node: MyApp.P2PNode}
      ]

  """

  use GenServer
  require Logger

  alias ElixirRpc.{P2P.Node, RequestResponse}
  alias ElixirRpc.P2P.Node.Event
  alias ElixirRpc.OTP.Distribution

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, server_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, server_opts, gen_opts)
  end

  @impl true
  def init(opts) do
    node = Keyword.fetch!(opts, :node)
    RequestResponse.register_handler(node)
    Logger.info("[ElixirRpc.OTP.Distribution.Server] Started for #{inspect(node)}")
    {:ok, %{node: node}}
  end

  @impl true
  def format_status(status), do: status

  @impl true
  def handle_info(
        {:libp2p, :inbound_request, %Event.InboundRequest{channel_id: channel_id, data: data}},
        state
      ) do
    case Distribution.decode(data) do
      {:ok, request} ->
        {:ok, response} = Distribution.handle_remote_request(request)
        RequestResponse.send_response(state.node, channel_id, response)

      {:error, :invalid_message} ->
        Logger.warning("[ElixirRpc.OTP.Distribution.Server] Received invalid message, ignoring")
        response = Distribution.encode({:error, :invalid_message})
        RequestResponse.send_response(state.node, channel_id, response)
    end

    {:noreply, state}
  end

  def handle_info({:libp2p, :outbound_response, _}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("[ElixirRpc.OTP.Distribution.Server] Unexpected: #{inspect(msg)}")
    {:noreply, state}
  end
end

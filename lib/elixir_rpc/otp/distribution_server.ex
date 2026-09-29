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

  alias ElixirRpc.RequestResponse
  alias ElixirRpc.P2P.Node.Event
  alias ElixirRpc.OTP.Distribution

  @spec call(GenServer.server(), ElixirRpc.PeerId.t(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :timeout | :unreachable}
  def call(node, peer, payload, timeout) do
    with node_pid when is_pid(node_pid) <- GenServer.whereis(node),
         router when is_pid(router) <- :global.whereis_name({__MODULE__, node_pid}) do
      GenServer.call(router, {:call, peer, payload, timeout}, :infinity)
    else
      _ -> {:error, :unreachable}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, server_opts} = Keyword.split(opts, [:name])
    node_pid = GenServer.whereis(Keyword.fetch!(server_opts, :node))
    name = Keyword.get(gen_opts, :name, {:global, {__MODULE__, node_pid}})
    GenServer.start_link(__MODULE__, server_opts, name: name)
  end

  @impl true
  def init(opts) do
    node = Keyword.fetch!(opts, :node)
    RequestResponse.register_handler(node)
    Logger.info("[ElixirRpc.OTP.Distribution.Server] Started for #{inspect(node)}")
    {:ok, %{node: node, pending: %{}}}
  end

  @impl true
  def format_status(status), do: status

  @impl true
  def handle_call({:call, peer, payload, timeout}, from, state) do
    case RequestResponse.send_request(state.node, peer, payload) do
      {:ok, request_id} ->
        token = make_ref()
        timer = Process.send_after(self(), {:call_timeout, request_id, token}, timeout)
        pending = Map.put(state.pending, request_id, {from, timer, token})
        {:noreply, %{state | pending: pending}}

      {:error, _reason} ->
        {:reply, {:error, :unreachable}, state}
    end
  end

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

  def handle_info(
        {:libp2p, :outbound_response,
         %Event.OutboundResponse{request_id: request_id, data: data}},
        state
      ) do
    case Map.pop(state.pending, request_id) do
      {{from, timer, _token}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, data})
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info({:call_timeout, request_id, token}, state) do
    case Map.get(state.pending, request_id) do
      {from, _timer, ^token} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: Map.delete(state.pending, request_id)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[ElixirRpc.OTP.Distribution.Server] Unexpected: #{inspect(msg)}")
    {:noreply, state}
  end
end

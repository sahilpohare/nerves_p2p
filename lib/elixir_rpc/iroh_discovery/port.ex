defmodule ElixirRpc.IrohDiscovery.Port do
  @moduledoc "A supervised client for the `iroh_discovery_port` executable."

  use GenServer

  @default_timeout 5_000

  defstruct [:port, next_id: 1, pending: %{}, subscribers: %{}]

  @type result :: {:ok, map()} | {:error, term()}

  @doc "Path of the daemon built by the `:iroh_discovery` compiler."
  @spec default_executable() :: Path.t()
  def default_executable, do: Application.app_dir(:elixir_rpc, "priv/bin/iroh_discovery_port")

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, port_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, port_opts, gen_opts)
  end

  @spec identity(GenServer.server(), timeout()) :: result()
  def identity(server, timeout \\ @default_timeout), do: call(server, "identity", %{}, timeout)

  @spec authorize(GenServer.server(), String.t(), String.t(), timeout()) :: result()
  def authorize(server, endpoint_id, node_name, timeout \\ @default_timeout) do
    call(
      server,
      "authorize",
      %{"endpoint_id" => endpoint_id, "node_name" => node_name},
      timeout
    )
  end

  @spec network_start(GenServer.server(), map() | nil, timeout()) :: result()
  def network_start(server, options \\ nil, timeout \\ @default_timeout)

  def network_start(server, nil, timeout), do: call(server, "network_start", %{}, timeout)

  def network_start(server, %{"endpoint_id" => _id} = bootstrap, timeout) do
    call(server, "network_start", %{"bootstrap" => bootstrap}, timeout)
  end

  def network_start(server, options, timeout) when is_map(options),
    do: call(server, "network_start", options, timeout)

  @spec publish(GenServer.server(), map(), timeout()) :: result()
  def publish(server, attributes, timeout \\ @default_timeout) do
    call(server, "publish", attributes, timeout)
  end

  @spec ingest(GenServer.server(), map(), timeout()) :: result()
  def ingest(server, attributes, timeout \\ @default_timeout) do
    call(server, "ingest", attributes, timeout)
  end

  @spec find(GenServer.server(), list(), timeout()) :: result()
  def find(server, predicates \\ [], timeout \\ @default_timeout) do
    call(server, "find", %{"predicates" => predicates}, timeout)
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(server, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(server, {:unsubscribe, subscriber})
  end

  @spec dist_listen(GenServer.server(), String.t(), timeout()) :: result()
  def dist_listen(server, node_name, timeout \\ @default_timeout) when is_binary(node_name) do
    call(server, "dist_listen", %{"node_name" => node_name}, timeout)
  end

  @spec dist_connect(GenServer.server(), String.t(), String.t(), timeout()) :: result()
  def dist_connect(server, from_node, target_node, timeout \\ @default_timeout)
      when is_binary(from_node) and is_binary(target_node) do
    call(
      server,
      "dist_connect",
      %{"from_node" => from_node, "target_node" => target_node},
      timeout
    )
  end

  @spec dist_send(GenServer.server(), non_neg_integer(), binary(), timeout()) :: result()
  def dist_send(server, stream_id, bytes, timeout \\ @default_timeout)
      when is_integer(stream_id) and stream_id >= 0 and is_binary(bytes) do
    call(
      server,
      "dist_send",
      %{"stream_id" => stream_id, "bytes" => Base.encode16(bytes, case: :lower)},
      timeout
    )
  end

  @spec dist_credit(GenServer.server(), non_neg_integer(), non_neg_integer(), timeout()) ::
          result()
  def dist_credit(server, stream_id, bytes, timeout \\ @default_timeout)
      when is_integer(stream_id) and stream_id >= 0 and is_integer(bytes) and bytes >= 0 do
    call(server, "dist_credit", %{"stream_id" => stream_id, "bytes" => bytes}, timeout)
  end

  @spec dist_close(GenServer.server(), non_neg_integer(), timeout()) :: result()
  def dist_close(server, stream_id, timeout \\ @default_timeout)
      when is_integer(stream_id) and stream_id >= 0 do
    call(server, "dist_close", %{"stream_id" => stream_id}, timeout)
  end

  @spec shutdown(GenServer.server(), timeout()) :: result()
  def shutdown(server, timeout \\ @default_timeout), do: call(server, "shutdown", %{}, timeout)

  @impl true
  def init(opts) do
    executable = Keyword.get_lazy(opts, :executable, &default_executable/0)

    arguments =
      Enum.map([:data_dir, :fleet_id, :node_name], fn key ->
        opts |> Keyword.fetch!(key) |> to_string() |> String.to_charlist()
      end)

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        {:packet, 4},
        :exit_status,
        args: arguments
      ])

    {:ok, %__MODULE__{port: port}}
  end

  @impl true
  def handle_call({:request, command, attributes, timeout}, from, state) do
    id = state.next_id

    request =
      attributes
      |> Map.drop([:id, :command, "id", "command"])
      |> Map.merge(%{"id" => id, "command" => command})

    case Jason.encode(request) do
      {:ok, payload} ->
        true = Port.command(state.port, payload)
        timer = Process.send_after(self(), {:request_timeout, id}, timeout)
        pending = Map.put(state.pending, id, {from, timer, command})
        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, subscriber, fn -> Process.monitor(subscriber) end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _subscribers} ->
        {:reply, :ok, state}

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  @impl true
  def handle_info({port, {:data, payload}}, %{port: port} = state) do
    handle_response(Jason.decode(payload), state)
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _timer, _command}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Enum.each(state.pending, fn {_id, {from, timer, _command}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, {:port_exit, status}})
    end)

    {:stop, {:port_exit, status}, %{state | pending: %{}}}
  end

  def handle_info({:DOWN, monitor, :process, subscriber, _reason}, state) do
    case state.subscribers do
      %{^subscriber => ^monitor} ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, subscriber)}}

      _subscribers ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp call(server, command, attributes, timeout)
       when is_map(attributes) and is_integer(timeout) and timeout >= 0 do
    GenServer.call(server, {:request, command, attributes, timeout}, :infinity)
  end

  defp handle_response({:ok, %{"event" => _name} = event}, state) do
    Enum.each(Map.keys(state.subscribers), &send(&1, {:iroh_dist, event}))
    {:noreply, state}
  end

  defp handle_response(
         {:ok, %{"id" => id, "ok" => true, "result" => result}},
         state
       )
       when is_integer(id) and is_map(result) do
    reply(id, {:ok, result}, state)
  end

  defp handle_response({:ok, %{"id" => id, "ok" => false, "error" => error}}, state)
       when is_integer(id) and is_binary(error) do
    reply(id, {:error, error}, state)
  end

  defp handle_response({:ok, %{"id" => id}}, state) when is_integer(id) do
    reply(id, {:error, :malformed_response}, state)
  end

  defp handle_response(_malformed, state), do: {:noreply, state}

  defp reply(id, reply, state) when is_integer(id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, timer, "shutdown"}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, reply)
        {:stop, :normal, %{state | pending: pending}}

      {{from, timer, _command}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, reply)
        {:noreply, %{state | pending: pending}}
    end
  end

  defp reply(_id, _reply, state), do: {:noreply, state}
end

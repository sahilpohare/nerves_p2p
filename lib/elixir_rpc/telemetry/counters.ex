defmodule ElixirRpc.Telemetry.Counters do
  @moduledoc """
  In-memory telemetry counter store with Prometheus text-format rendering.

  Subscribes to the events listed in `ElixirRpc.Telemetry.event_names/0` and
  increments a counter per `{event, result_tag}` pair.

  ## Usage

      Plug.Conn.send_resp(conn, 200,
        ElixirRpc.Telemetry.Counters.render_prometheus())

  """

  use GenServer
  require Logger

  alias ElixirRpc.Telemetry

  defstruct counts: %{}, attached?: false

  @type result_tag :: :ok | :error | :unknown
  @type counter_key :: {event :: [atom()], result_tag()}
  @type snapshot :: %{counter_key() => non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gen_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(counters \\ __MODULE__), do: GenServer.call(counters, :snapshot)

  @spec render_prometheus(GenServer.server()) :: String.t()
  def render_prometheus(counters \\ __MODULE__) do
    counters |> snapshot() |> do_render_prometheus()
  end

  @spec reset(GenServer.server()) :: :ok
  def reset(counters \\ __MODULE__), do: GenServer.call(counters, :reset)

  @spec sync(GenServer.server()) :: :ok
  def sync(counters \\ __MODULE__), do: GenServer.call(counters, :sync)

  @impl true
  def init(_opts) do
    handler_id = "elixir_rpc_counters_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        Telemetry.event_names(),
        &__MODULE__.handle_event/4,
        %{counters: self()}
      )

    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{attached?: true, counts: %{handler_id: handler_id}}}
  end

  @doc false
  def handle_event(event, _measurements, metadata, %{counters: counters}) do
    result_tag =
      case Map.get(metadata, :result) do
        :ok -> :ok
        :error -> :error
        _ -> :unknown
      end

    GenServer.cast(counters, {:increment, event, result_tag})
  end

  @impl true
  def handle_cast({:increment, event, result_tag}, state) do
    counts = Map.update(state.counts, {event, result_tag}, 1, &(&1 + 1))
    {:noreply, %{state | counts: counts}}
  end

  def handle_cast(unknown, state) do
    Logger.warning("[ElixirRpc.Telemetry.Counters] Unknown cast: #{inspect(unknown)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    user_counts =
      state.counts
      |> Enum.reject(fn {k, _v} -> k == :handler_id end)
      |> Map.new()

    {:reply, user_counts, state}
  end

  def handle_call(:reset, _from, state) do
    handler_id = Map.get(state.counts, :handler_id)
    {:reply, :ok, %{state | counts: %{handler_id: handler_id}}}
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call(unknown, _from, state) do
    Logger.warning("[ElixirRpc.Telemetry.Counters] Unknown call: #{inspect(unknown)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def terminate(_reason, %{counts: %{handler_id: handler_id}}) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(%{state: %__MODULE__{} = state} = status) do
    summary = %{
      attached?: state.attached?,
      counter_count: state.counts |> Map.delete(:handler_id) |> map_size()
    }

    %{status | state: summary}
  end

  def format_status(status), do: status

  defp do_render_prometheus(snapshot) when map_size(snapshot) == 0 do
    "# ElixirRpc telemetry counters (no events recorded yet)\n"
  end

  defp do_render_prometheus(snapshot) do
    snapshot
    |> Enum.group_by(fn {{event, _result}, _count} -> event end)
    |> Enum.sort_by(fn {event, _entries} -> event end)
    |> Enum.flat_map(&render_metric_family/1)
    |> IO.iodata_to_binary()
  end

  defp render_metric_family({event, entries}) do
    metric_name = metric_name_for(event)

    header = [
      "# HELP ", metric_name, "_total Number of [",
      Enum.map_join(event, ", ", &Atom.to_string/1),
      "] events fired, partitioned by result.\n",
      "# TYPE ", metric_name, "_total counter\n"
    ]

    body =
      entries
      |> Enum.sort_by(fn {{_event, result}, _count} -> result end)
      |> Enum.map(fn {{_event, result}, count} ->
        [metric_name, "_total{result=\"", Atom.to_string(result), "\"} ",
         Integer.to_string(count), "\n"]
      end)

    [header, body, "\n"]
  end

  defp metric_name_for(event) do
    event |> Enum.map_join("_", &Atom.to_string/1)
  end
end

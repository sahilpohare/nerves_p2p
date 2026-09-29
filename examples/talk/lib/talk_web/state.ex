defmodule ElixirRpc.TalkWeb.State do
  @moduledoc false

  use GenServer

  defstruct status: "idle",
            phase: "idle",
            events: [],
            stages: %{},
            daemons: %{},
            selected_peer: nil,
            subscribers: %{},
            run_ref: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, start_options(opts))
  end

  @spec get(GenServer.server()) :: map()
  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @spec emit(GenServer.server(), map()) :: :ok
  def emit(server \\ __MODULE__, event) when is_map(event),
    do: GenServer.cast(server, {:emit, event})

  @spec run(GenServer.server(), GenServer.server(), (-> any())) ::
          :ok | {:error, :already_running}
  def run(server \\ __MODULE__, task_supervisor, fun) when is_function(fun, 0) do
    GenServer.call(server, {:run, task_supervisor, fun})
  end

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:get, _from, state) do
    snapshot =
      Map.take(state, [:status, :phase, :events, :stages, :daemons, :selected_peer])

    {:reply, snapshot, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:run, _task_supervisor, _fun}, _from, %{run_ref: ref} = state)
      when is_reference(ref) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:run, task_supervisor, fun}, _from, state) do
    task = fn ->
      receive do
        :run -> fun.()
      end
    end

    case Task.Supervisor.start_child(task_supervisor, task) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        send(pid, :run)

        state = %{
          state
          | status: "running",
            phase: "discovery",
            events: [],
            stages: %{"discovery" => "active"},
            daemons: %{},
            selected_peer: nil,
            run_ref: ref
        }

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:emit, event}, state) do
    Enum.each(Map.keys(state.subscribers), &send(&1, {:talk_event, event}))
    {:noreply, apply_event(state, event)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run_ref: ref} = state) do
    finish_run(reason, %{state | run_ref: nil})
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.subscribers, pid) do
      ^ref -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
      _ -> {:noreply, state}
    end
  end

  defp finish_run(:normal, state) do
    stages = Map.new(state.stages, fn {stage, _status} -> {stage, "done"} end)
    {:noreply, %{state | status: "success", phase: "complete", stages: stages}}
  end

  defp finish_run(reason, state) do
    event = %{
      type: "error",
      stage: "failed",
      status: "error",
      message: Exception.format_exit(reason),
      at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      data: %{}
    }

    Enum.each(Map.keys(state.subscribers), &send(&1, {:talk_event, event}))

    {:noreply,
     %{state | status: "error", phase: "failed", events: Enum.take(state.events ++ [event], -100)}}
  end

  defp apply_event(state, event) do
    data = Map.get(event, :data, %{})
    stage = Map.get(event, :stage, state.phase)
    event_status = Map.get(event, :status, "running")

    status =
      case event_status do
        "error" -> "error"
        "running" -> "running"
        _ -> state.status
      end

    stage_status = if event_status == "running", do: "active", else: event_status

    %{
      state
      | status: status,
        phase: stage,
        stages: Map.put(state.stages, stage, stage_status),
        daemons: Map.merge(state.daemons, Map.get(data, :daemons, %{})),
        selected_peer: Map.get(data, :peer, state.selected_peer),
        events: Enum.take(state.events ++ [event], -100)
    }
  end

  defp start_options(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> []
      name -> [name: name]
    end
  end
end

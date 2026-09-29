defmodule ElixirRpc.TalkWeb.StateTest do
  use ExUnit.Case, async: true

  alias ElixirRpc.TalkWeb.State

  setup do
    state = start_supervised!({State, name: nil})
    tasks = start_supervised!({Task.Supervisor, []})
    %{state: state, tasks: tasks}
  end

  test "P[state has a subscriber] C[publish an event] Q[event is stored and delivered]", %{
    state: state
  } do
    assert :ok = State.subscribe(state)

    event = %{
      type: "stage",
      stage: "discovery",
      status: "running",
      message: "starting",
      at: "now",
      data: %{}
    }

    assert :ok = State.emit(state, event)
    assert_receive {:talk_event, ^event}
    assert %{status: "running", phase: "discovery", events: [^event]} = State.get(state)
  end

  test "P[a demo run is active] C[start another run] Q[the concurrent run is rejected]", %{
    state: state,
    tasks: tasks
  } do
    test = self()

    assert :ok = State.run(state, tasks, fn -> receive do: (:finish -> send(test, :finished)) end)
    assert {:error, :already_running} = State.run(state, tasks, fn -> :ok end)

    [task] = Task.Supervisor.children(tasks)
    send(task, :finish)
    assert_receive :finished
    assert_eventually(fn -> State.get(state).phase == "complete" end)
  end

  defp assert_eventually(fun) do
    assert_eventually(fun, 50)
  end

  defp assert_eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      true -> :ok
      false -> Process.sleep(5) && assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met")
end

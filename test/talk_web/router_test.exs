defmodule ElixirRpc.TalkWeb.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ElixirRpc.TalkWeb.{Router, State}

  setup do
    state = start_supervised!({State, name: nil})
    tasks = start_supervised!({Task.Supervisor, []})
    %{opts: Router.init(state: state, task_supervisor: tasks), state: state, tasks: tasks}
  end

  test "P[dashboard state exists] C[GET api state] Q[JSON state returns]", %{opts: opts} do
    conn = Router.call(conn(:get, "/api/state"), opts)

    assert conn.status == 200

    assert %{"status" => "idle", "phase" => "idle", "events" => []} =
             Jason.decode!(conn.resp_body)
  end

  test "P[the run endpoint is idle] C[POST twice] Q[one demo starts and one is rejected]", %{
    opts: opts,
    tasks: tasks
  } do
    blocker = self()

    opts =
      Keyword.put(opts, :demo, fn _emit -> receive do: (:finish -> send(blocker, :finished)) end)

    assert %{status: 202} = Router.call(conn(:post, "/api/run"), opts)
    conn = Router.call(conn(:post, "/api/run"), opts)
    assert conn.status == 409
    assert %{"error" => "already_running"} = Jason.decode!(conn.resp_body)

    [task] = Task.Supervisor.children(tasks)
    send(task, :finish)
    assert_receive :finished
  end

  test "P[dashboard assets exist] C[GET root] Q[the talk dashboard is served]", %{opts: opts} do
    conn = Router.call(conn(:get, "/"), opts)
    assert conn.status == 200
    assert conn.resp_body =~ "CAPABILITY HANDOFF"
    assert conn.resp_body =~ "RUN DEMO"
  end
end

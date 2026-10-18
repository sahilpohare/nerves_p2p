defmodule ElixirRpc.TalkWeb.Router do
  @moduledoc false

  use Plug.Router

  alias ElixirRpc.TalkDemo
  alias ElixirRpc.TalkWeb.State

  plug(Plug.Static, at: "/", from: {:elixir_rpc, "priv/talk_ui"})
  plug(:match)
  plug(:dispatch)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn
    |> assign(:state, Keyword.get(opts, :state, State))
    |> assign(
      :task_supervisor,
      Keyword.get(opts, :task_supervisor, ElixirRpc.TalkWeb.TaskSupervisor)
    )
    |> assign(:demo, Keyword.get(opts, :demo, &TalkDemo.run([], &1)))
    |> assign(:heartbeat, Keyword.get(opts, :heartbeat, 15_000))
    |> super(opts)
  end

  get "/" do
    send_file(conn, 200, Application.app_dir(:elixir_rpc, "priv/talk_ui/index.html"))
  end

  get "/api/state" do
    json(conn, 200, State.get(conn.assigns.state))
  end

  get "/api/events" do
    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)

    :ok = State.subscribe(conn.assigns.state)
    stream(conn, conn.assigns.heartbeat)
  end

  post "/api/run" do
    state = conn.assigns.state
    demo = conn.assigns.demo

    case State.run(state, conn.assigns.task_supervisor, fn -> demo.(&State.emit(state, &1)) end) do
      :ok -> json(conn, 202, %{status: "started"})
      {:error, :already_running} -> json(conn, 409, %{error: "already_running"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp stream(conn, heartbeat) do
    receive do
      {:talk_event, event} -> continue(conn, heartbeat, ["data: ", Jason.encode!(event), "\n\n"])
    after
      heartbeat -> continue(conn, heartbeat, ": heartbeat\n\n")
    end
  end

  defp continue(conn, heartbeat, payload) do
    case chunk(conn, payload) do
      {:ok, conn} -> stream(conn, heartbeat)
      {:error, _reason} -> conn
    end
  end
end

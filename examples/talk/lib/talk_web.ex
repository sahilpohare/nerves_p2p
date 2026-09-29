defmodule ElixirRpc.TalkWeb do
  @moduledoc "Opt-in supervisor for the browser talk dashboard."

  use Supervisor

  alias ElixirRpc.TalkWeb.{Router, State}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = Keyword.get(opts, :state_name, State)
    tasks = Keyword.get(opts, :task_supervisor_name, ElixirRpc.TalkWeb.TaskSupervisor)

    router_opts =
      opts
      |> Keyword.take([:demo, :heartbeat])
      |> Keyword.merge(state: state, task_supervisor: tasks)

    children = [
      {State, name: state},
      {Task.Supervisor, name: tasks},
      {Bandit,
       plug: {Router, router_opts},
       scheme: :http,
       ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
       port: Keyword.get(opts, :port, 4000)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

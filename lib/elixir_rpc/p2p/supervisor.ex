defmodule ElixirRpc.P2P.Supervisor do
  @moduledoc """
  Supervision tree for the P2P primitive layer.

  Start order:
    1. `HandlerRegistry` — must exist before any Node can dispatch events.
    2. `NodeSupervisor` — DynamicSupervisor for Node instances.

  `rest_for_one`: if HandlerRegistry crashes, NodeSupervisor restarts too
  (its nodes would hold stale registry references otherwise).
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ElixirRpc.P2P.Node.HandlerRegistry,
      {DynamicSupervisor, name: ElixirRpc.P2P.NodeSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

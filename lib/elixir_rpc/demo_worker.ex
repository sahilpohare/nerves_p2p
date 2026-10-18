defmodule ElixirRpc.DemoWorker do
  @moduledoc """
  Talk demo job. Lives in `lib/` so prod firmware ships it; closures defined in
  `examples/` do not exist on the remote node.
  """

  @spec report(pid(), term()) :: term()
  def report(caller, id), do: send(caller, {id, {:demo_result, id, node()}})
end

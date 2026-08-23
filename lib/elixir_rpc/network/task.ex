defmodule ElixirRpc.Network.Task do
  @moduledoc """
  Distributed task execution via Horde.DynamicSupervisor.

  Spawns tasks under the cluster-wide dynamic supervisor so they can run
  on any node in the mesh. Uses a caller-owned mailbox pattern for await.

  ## Usage

      task = ElixirRpc.Network.Task.async(fn -> heavy_computation() end)
      result = ElixirRpc.Network.Task.await(task)
  """

  @supervisor ElixirRpc.DynamicSupervisor

  defstruct [:ref, :pid]

  @type t :: %__MODULE__{ref: reference(), pid: pid()}

  @doc """
  Spawn `fun` under the Horde DynamicSupervisor and return a task handle.
  The result of `fun` is sent back to the caller when complete.
  """
  @spec async(fun()) :: t()
  def async(fun) when is_function(fun, 0) do
    caller = self()
    ref = make_ref()

    spec = %{
      id: ref,
      start:
        {Task, :start_link,
         [
           fn ->
             result = fun.()
             send(caller, {ref, result})
           end
         ]},
      restart: :temporary
    }

    {:ok, pid} = Horde.DynamicSupervisor.start_child(@supervisor, spec)
    %__MODULE__{ref: ref, pid: pid}
  end

  @doc """
  Wait for the result of a task. Raises on timeout.
  """
  @spec await(t(), timeout()) :: term()
  def await(%__MODULE__{ref: ref}, timeout \\ 5_000) do
    receive do
      {^ref, result} -> result
    after
      timeout -> raise "ElixirRpc.Network.Task.await timed out after #{timeout}ms"
    end
  end
end

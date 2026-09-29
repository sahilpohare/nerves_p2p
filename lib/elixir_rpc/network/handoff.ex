defmodule ElixirRpc.Network.Handoff do
  @moduledoc "Starts a uniquely identified Horde child on an already-selected BEAM node."

  use GenServer

  @supervisor ElixirRpc.DynamicSupervisor
  @registry ElixirRpc.Registry
  @default_timeout 5_000
  @poll_interval 10
  @target_unavailable_prefix "target node is not an alive Horde member: "

  @doc "Waits for target membership and idempotently starts the child there."
  @spec start_child(node(), Supervisor.child_spec(), non_neg_integer()) ::
          {:ok, pid()} | {:error, term()}
  def start_child(target_node, child_spec, timeout \\ @default_timeout)
      when is_atom(target_node) and is_integer(timeout) and timeout >= 0 do
    child_spec = Supervisor.child_spec(child_spec, [])

    with :ok <- await_membership(target_node, timeout),
         {:ok, _id} <- fetch_id(child_spec) do
      target_spec = put_target(child_spec, target_node)
      normalize_start(Horde.DynamicSupervisor.start_child(@supervisor, target_spec))
    end
  end

  @doc false
  def start_link(child_spec) do
    name = {:via, Horde.Registry, {@registry, {__MODULE__, child_spec.id}}}
    GenServer.start_link(__MODULE__, child_spec, name: name)
  end

  @impl GenServer
  def init(%{start: {module, function, args}}) do
    case apply(module, function, args) do
      {:ok, pid} -> monitor_child(pid)
      {:ok, pid, _extra} -> monitor_child(pid)
      :ignore -> :ignore
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %{pid: pid, ref: ref} = state) do
    {:stop, reason, state}
  end

  defp monitor_child(pid), do: {:ok, %{pid: pid, ref: Process.monitor(pid)}}

  defp await_membership(target_node, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_membership_until(target_node, deadline)
  end

  defp await_membership_until(target_node, deadline) do
    case Enum.any?(Horde.Cluster.members(@supervisor), &member_on?(&1, target_node)) do
      true ->
        :ok

      false ->
        wait_or_timeout(target_node, deadline)
    end
  end

  defp wait_or_timeout(target_node, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining <= 0 ->
        {:error, :peer_unavailable}

      remaining ->
        Process.sleep(min(@poll_interval, remaining))
        await_membership_until(target_node, deadline)
    end
  end

  defp member_on?({_supervisor, node}, target_node), do: node == target_node
  defp member_on?(_member, _target_node), do: false

  defp fetch_id(%{id: nil}), do: {:error, :child_spec_requires_id}
  defp fetch_id(%{id: id}), do: {:ok, id}

  defp put_target(child_spec, target_node) do
    meta =
      child_spec |> Map.get(:meta, %{}) |> Map.new() |> Map.put(:cdp_target_node, target_node)

    %{child_spec | start: {__MODULE__, :start_link, [child_spec]}}
    |> Map.put(:meta, meta)
  end

  defp normalize_start({:error, {:already_started, pid}}), do: {:ok, pid}

  defp normalize_start({:error, <<@target_unavailable_prefix, _::binary>>}),
    do: {:error, :peer_unavailable}

  defp normalize_start(result), do: result
end

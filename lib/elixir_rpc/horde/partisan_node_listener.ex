defmodule ElixirRpc.Horde.PartisanNodeListener do
  @moduledoc """
  A Horde node listener for Partisan-based clusters.

  Uses `:partisan.monitor_nodes/1` for node monitoring and
  `:partisan_peer_service` for membership, replacing the default
  Erlang distribution assumptions in `Horde.NodeListenerBehaviour`.

  ## Usage

      {Horde.Registry,
        name: MyRegistry,
        keys: :unique,
        members: {:auto, ElixirRpc.Horde.PartisanNodeListener}}
  """

  use Horde.NodeListenerBehaviour

  @impl GenServer
  def init(cluster) do
    apply(:partisan, :monitor_nodes, [true])
    {:ok, cluster}
  end

  @impl Horde.NodeListenerBehaviour
  def make_members(cluster) do
    case partisan_members() do
      {:ok, members} when is_list(members) ->
        Enum.map(members, &{cluster, &1})

      members when is_list(members) ->
        Enum.map(members, &{cluster, &1})

      _ ->
        [{cluster, partisan_name()}]
    end
  end

  @impl Horde.NodeListenerBehaviour
  def handle_nodeup(_node, cluster), do: set_members(cluster)

  @impl Horde.NodeListenerBehaviour
  def handle_nodedown(_node, cluster), do: set_members(cluster)

  # Partisan emits 2-tuple {:nodeup, node} / {:nodedown, node} — no node_type
  @impl GenServer
  def handle_info({:nodeup, node}, cluster) do
    handle_nodeup(node, cluster)
    {:noreply, cluster}
  end

  @impl GenServer
  def handle_info({:nodedown, node}, cluster) do
    handle_nodedown(node, cluster)
    {:noreply, cluster}
  end

  defp partisan_members, do: apply(:partisan_peer_service, :members, [])
  defp partisan_name, do: apply(:partisan_config, :get, [:name])
end

defmodule ElixirRpc.Horde.PartisanNodeListener do
  @moduledoc """
  A Horde node listener for Partisan-based clusters.

  Polls `:partisan_peer_service.members/0` on a timer instead of subscribing
  to push notifications: `:partisan.monitor_nodes/1` depends on the peer
  service manager implementing `on_up/2`/`on_down/2`, which
  `partisan_hyparview_peer_service_manager` (a partial-view protocol with no
  concept of global membership) never does — it's a hard `{error,
  not_implemented}` in hyparview, not a transient failure.

  ## Usage

      {Horde.Registry,
        name: MyRegistry,
        keys: :unique,
        members: {:auto, ElixirRpc.Horde.PartisanNodeListener}}
  """

  use Horde.NodeListenerBehaviour

  # ponytail: polling delay before Horde sees a new/departed peer; lower if
  # placement latency after join matters more than poll overhead.
  @poll_interval 1_000

  @impl GenServer
  def init(cluster) do
    schedule_poll()
    {:ok, {cluster, partisan_members()}}
  end

  @impl Horde.NodeListenerBehaviour
  def make_members(cluster), do: Enum.map(partisan_members(), &{cluster, &1})

  @impl GenServer
  def handle_info(:poll, {cluster, last_members}) do
    schedule_poll()

    case partisan_members() do
      ^last_members ->
        {:noreply, {cluster, last_members}}

      members ->
        set_members(cluster)
        {:noreply, {cluster, members}}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval)

  defp partisan_members do
    case apply(:partisan_peer_service, :members, []) do
      {:ok, members} when is_list(members) -> members
      members when is_list(members) -> members
      _ -> [apply(:partisan_config, :get, [:name])]
    end
  end
end

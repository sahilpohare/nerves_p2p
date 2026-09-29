defmodule ElixirRpc.Network.CapabilityDistributionStrategy do
  @moduledoc """
  A Horde distribution strategy that routes processes to nodes based on
  which modules are loaded there.

  Each node advertises its loaded modules into Horde.Registry via
  `ElixirRpc.Network.ModuleRegistry`. This module queries that registry
  locally — no cross-node RPC or Erlang distribution required, making it
  fully compatible with Partisan.

  ## Usage

      Horde.DynamicSupervisor.start_child(ElixirRpc.DynamicSupervisor, %{
        id: MyWorker,
        start: {MyWorker, :start_link, [args]},
        meta: [requires: [MyWorker, SomeDependency]]
      })

  Falls back to hash-ring placement if no constraints are given or no
  matching node is found.
  """

  @behaviour Horde.DistributionStrategy

  alias ElixirRpc.Network.ModuleRegistry

  @impl true
  def choose_node(child_spec, members) do
    alive = Enum.filter(members, &match?(%{status: :alive}, &1))

    case get_in(child_spec, [:meta, :cdp_target_node]) do
      nil -> choose_by_requirements(child_spec, alive)
      target_node -> choose_target(target_node, alive)
    end
  end

  defp choose_target(target_node, alive) do
    case Enum.find(alive, fn %{name: {_supervisor, node}} -> node == target_node end) do
      nil -> {:error, "target node is not an alive Horde member: #{inspect(target_node)}"}
      member -> {:ok, member}
    end
  end

  defp choose_by_requirements(child_spec, alive) do
    case alive do
      [] ->
        {:error, "no alive nodes"}

      alive ->
        required_modules = get_in(child_spec, [:meta, :requires]) || []

        candidates =
          case required_modules do
            [] ->
              alive

            modules ->
              Enum.filter(alive, fn member ->
                {_supervisor, node} = member.name
                node_modules = ModuleRegistry.modules_for(node)
                Enum.all?(modules, &MapSet.member?(node_modules, &1))
              end)
          end

        case candidates do
          [] ->
            {:error, "no node has required modules: #{inspect(required_modules)}"}

          candidates ->
            identifier = :erlang.phash2(Map.drop(child_spec, [:id]))

            chosen =
              candidates
              |> Enum.map(& &1.name)
              |> then(&(HashRing.new() |> HashRing.add_nodes(&1)))
              |> HashRing.key_to_node(identifier)

            {:ok, Enum.find(candidates, &(&1.name == chosen))}
        end
    end
  end

  @impl true
  def has_quorum?(_members), do: true
end

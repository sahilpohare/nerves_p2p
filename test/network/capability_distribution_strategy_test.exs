defmodule ElixirRpc.Network.CapabilityDistributionStrategyTest do
  use ExUnit.Case, async: true

  alias ElixirRpc.Network.CapabilityDistributionStrategy
  alias Horde.DynamicSupervisor.Member

  test "P[the target member is alive] C[choose a node] Q[the exact target is selected]" do
    selected = %Member{status: :alive, name: {:supervisor, :selected@host}}
    other = %Member{status: :alive, name: {:supervisor, :other@host}}

    child_spec = %{
      id: :worker,
      start: {Agent, :start_link, [fn -> nil end]},
      meta: %{cdp_target_node: :selected@host, requires: [:missing_module]}
    }

    assert {:ok, ^selected} =
             CapabilityDistributionStrategy.choose_node(child_spec, [other, selected])
  end

  test "P[the target member is dead] C[choose a node] Q[selection errors without fallback]" do
    dead = %Member{status: :dead, name: {:supervisor, :selected@host}}
    other = %Member{status: :alive, name: {:supervisor, :other@host}}

    child_spec = %{
      id: :worker,
      start: {Agent, :start_link, [fn -> nil end]},
      meta: %{cdp_target_node: :selected@host}
    }

    assert {:error, "target node is not an alive Horde member: :selected@host"} =
             CapabilityDistributionStrategy.choose_node(child_spec, [dead, other])
  end

  test "P[no target is explicit] C[choose a node] Q[requirements placement is used]" do
    member = %Member{status: :alive, name: {:supervisor, node()}}
    child_spec = %{id: :worker, start: {Agent, :start_link, [fn -> nil end]}, meta: %{}}

    assert {:ok, ^member} = CapabilityDistributionStrategy.choose_node(child_spec, [member])
  end
end

defmodule ElixirRpc.Network.HandoffTest do
  use ExUnit.Case, async: false

  alias ElixirRpc.Network.Handoff

  test "P[a target is a Horde member] C[start the same child twice] Q[one child starts idempotently]" do
    id = make_ref()
    spec = %{id: id, start: {Agent, :start_link, [fn -> :started end]}}

    assert {:ok, pid} = Handoff.start_child(node(), spec, 100)
    on_exit(fn -> Horde.DynamicSupervisor.terminate_child(ElixirRpc.DynamicSupervisor, pid) end)

    assert {:ok, ^pid} = Handoff.start_child(node(), spec, 100)
    assert Process.alive?(pid)
  end

  test "P[a target is absent] C[wait for membership] Q[peer_unavailable returns within the bound]" do
    spec = %{id: make_ref(), start: {Agent, :start_link, [fn -> nil end]}}

    assert {:error, :peer_unavailable} = Handoff.start_child(:missing@host, spec, 10)
  end
end

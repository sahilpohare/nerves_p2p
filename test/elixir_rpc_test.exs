defmodule ElixirRpcTest do
  use ExUnit.Case
  doctest ElixirRpc

  test "P[the module is loaded] C[call hello] Q[world is returned]" do
    assert ElixirRpc.hello() == :world
  end
end

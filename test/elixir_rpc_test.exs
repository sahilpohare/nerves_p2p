defmodule ElixirRpcTest do
  use ExUnit.Case
  doctest ElixirRpc

  test "greets the world" do
    assert ElixirRpc.hello() == :world
  end
end

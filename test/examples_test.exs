defmodule ElixirRpc.ExamplesTest do
  use ExUnit.Case, async: true

  test "library examples remain valid and atom-safe" do
    for path <- ["examples/capabilities.exs", "examples/start_child.exs"] do
      source = File.read!(path)

      assert {:ok, _ast} = Code.string_to_quoted(source)
      refute source =~ "String.to_atom"
    end
  end
end

defmodule ElixirRpc do
  @moduledoc """
  Documentation for `ElixirRpc`.
  """

  @doc """
  Hello world.

  P: the `ElixirRpc` module is loaded.
  C: `hello/0` is called.
  Q: it returns `:world`.

  ## Examples

      iex> ElixirRpc.hello()
      :world

  """
  def hello do
    IO.puts("hello")
    :world
  end
end

defmodule ElixirRpc.P2P.Node.Result do
  @moduledoc false

  @type call_result :: :ok | {:ok, term()} | {:error, term()} | term()

  @spec normalize_ok(call_result()) :: call_result()
  def normalize_ok({:ok, _}), do: :ok
  def normalize_ok({:error, _} = err), do: err
  def normalize_ok(other), do: other

  @spec tag(call_result()) :: :ok | :error | :unknown
  def tag(:ok), do: :ok
  def tag({:ok, _}), do: :ok
  def tag({:error, _}), do: :error
  def tag(_), do: :unknown
end

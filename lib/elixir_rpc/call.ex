defmodule ElixirRpc.Call do
  @moduledoc false

  @default_timeout 15_000

  @spec safe_call(GenServer.server(), term(), timeout()) ::
          term() | {:error, {:node_unavailable, term()}}
  def safe_call(server, message, timeout \\ @default_timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, reason -> {:error, {:node_unavailable, reason}}
  end
end

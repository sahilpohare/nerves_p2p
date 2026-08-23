defmodule ElixirRpc.CapabilityRPC.Server do
  @moduledoc """
  Handles inbound capability-based RPC calls dispatched by `ElixirRpc.CapabilityRPC`.

  This GenServer is registered as `:__capability_rpc_server__` so that
  `ElixirRpc.OTP.Distribution` can route `{:apply, module, function, args}`
  messages to it.

  Add to your supervision tree:

      children = [ElixirRpc.CapabilityRPC.Server]
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: :__capability_rpc_server__)
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:apply, module, function, args}, _from, state) do
    result =
      try do
        {:ok, apply(module, function, args)}
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, inspect(reason)}}
        kind, reason -> {:error, {kind, inspect(reason)}}
      end

    {:reply, result, state}
  end

  def handle_call(unknown, _from, state) do
    Logger.warning("[CapabilityRPC.Server] Unknown call: #{inspect(unknown)}")
    {:reply, {:error, :unknown_call}, state}
  end
end

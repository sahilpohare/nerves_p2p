defmodule ElixirRpc.Network.ModuleRegistry do
  @moduledoc """
  Advertises this node's loaded modules into Horde.Registry so that
  the capability distribution strategy can route processes without
  cross-node RPC calls.

  Each node registers `{node(), :modules}` -> MapSet of loaded modules.
  Since Horde.Registry is CRDT-replicated, every node has a full view.
  """

  use GenServer
  require Logger

  @registry ElixirRpc.Registry

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Look up which modules are loaded on a given node."
  @spec modules_for(node()) :: MapSet.t()
  def modules_for(node) do
    case Horde.Registry.lookup(@registry, {node, :modules}) do
      [{_pid, modules}] -> modules
      _ -> MapSet.new()
    end
  end

  @impl GenServer
  def init(_) do
    # Wait for Horde.Registry to be ready
    Process.send_after(self(), :register, 500)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:register, _state) do
    modules = all_loaded_modules()

    case Horde.Registry.register(@registry, {node(), :modules}, modules) do
      {:ok, _} ->
        Logger.info("ModuleRegistry: advertised #{MapSet.size(modules)} modules for #{node()}")

      {:error, {:already_registered, _}} ->
        Horde.Registry.unregister(@registry, {node(), :modules})
        Horde.Registry.register(@registry, {node(), :modules}, modules)
    end

    {:noreply, modules}
  end

  defp all_loaded_modules do
    :code.all_loaded()
    |> Enum.map(fn {module, _path} -> module end)
    |> MapSet.new()
  end
end

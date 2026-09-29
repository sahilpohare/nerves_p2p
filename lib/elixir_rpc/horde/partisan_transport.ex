defmodule ElixirRpc.Horde.PartisanTransport do
  @moduledoc "Cluster transport using Partisan for peer communication."

  @behaviour Horde.ClusterTransport

  @impl true
  def members() do
    case partisan_members() do
      {:ok, members} when is_list(members) ->
        Enum.reject(members, &(&1 == partisan_name()))

      members when is_list(members) ->
        Enum.reject(members, &(&1 == partisan_name()))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @impl true
  def process_alive?(pid) when node(pid) == node(), do: Process.alive?(pid)

  def process_alive?(pid) do
    n = node(pid)

    if peer?(n) do
      try do
        partisan_call(n, Process, :alive?, [pid], 5_000)
      catch
        _, _ -> false
      end
    else
      false
    end
  end

  @impl true
  def call(node, mod, fun, args, timeout) do
    partisan_call(node, mod, fun, args, timeout)
  end

  defp peer?(node) do
    case partisan_members() do
      {:ok, members} when is_list(members) -> node in members
      members when is_list(members) -> node in members
      _ -> false
    end
  rescue
    _ -> false
  end

  defp partisan_members, do: apply(:partisan_peer_service, :members, [])
  defp partisan_name, do: apply(:partisan_config, :get, [:name])

  defp partisan_call(node, mod, fun, args, timeout),
    do: apply(:partisan_rpc, :call, [node, mod, fun, args, timeout])
end

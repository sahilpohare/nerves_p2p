defmodule ElixirRpc.IrohDistribution do
  @moduledoc "Starts OTP distribution after the Iroh network is ready."

  @spec start() :: :ok | {:error, term()}
  def start do
    with :ok <- require_iroh_protocol(),
         {:ok, node_name} <- configured_node() do
      start_node(node_name, Node.alive?())
    end
  end

  defp require_iroh_protocol do
    case :init.get_argument(:proto_dist) do
      {:ok, values} ->
        case Enum.any?(values, fn arguments -> ~c"iroh" in arguments end) do
          true -> :ok
          false -> {:error, :iroh_protocol_not_selected}
        end

      :error ->
        {:error, :iroh_protocol_not_selected}
    end
  end

  defp configured_node do
    partisan_node = :partisan_config.get(:name)
    configured = Application.fetch_env!(:elixir_rpc, :iroh_discovery)[:node_name]

    case is_atom(partisan_node) and Atom.to_string(partisan_node) == to_string(configured) do
      true -> {:ok, partisan_node}
      false -> {:error, :node_name_mismatch}
    end
  end

  defp start_node(node_name, false) do
    case :net_kernel.start([node_name, name_domain(node_name)]) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_node(node_name, true) do
    case Node.self() == node_name do
      true -> :ok
      false -> {:error, :different_node_already_started}
    end
  end

  defp name_domain(node_name) do
    [_name, host] = node_name |> Atom.to_string() |> String.split("@")
    if String.contains?(host, "."), do: :longnames, else: :shortnames
  end
end

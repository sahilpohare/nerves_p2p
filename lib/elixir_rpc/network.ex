defmodule ElixirRpc.Network do
  @moduledoc "Capability discovery and targeted Horde handoff."

  alias ElixirRpc.IrohDiscovery.Port
  alias ElixirRpc.Network.Handoff
  alias ElixirRpc.TalkWorker

  @doc "Returns all currently discoverable peers."
  @spec capabilities(GenServer.server()) :: Port.result()
  def capabilities(discovery \\ ElixirRpc.IrohDiscovery), do: Port.find(discovery)

  @doc "Publishes this node's complete capability snapshot immediately."
  @spec advertise(map() | keyword()) :: Port.result()
  def advertise(capabilities) when is_map(capabilities), do: TalkWorker.advertise(capabilities)

  def advertise(capabilities) when is_list(capabilities) do
    case Keyword.keyword?(capabilities) do
      true -> capabilities |> Map.new() |> advertise()
      false -> {:error, {:invalid_capabilities, capabilities}}
    end
  end

  def advertise(capabilities), do: {:error, {:invalid_capabilities, capabilities}}

  @doc "Runs a zero-argument function on a peer selected by capability."
  @spec spawn(map() | keyword(), (-> term())) :: {:ok, pid()} | {:error, term()}
  def spawn(requirements, fun) when is_list(requirements) and is_function(fun, 0) do
    case Keyword.keyword?(requirements) do
      true -> requirements |> Map.new() |> spawn(fun)
      false -> {:error, {:invalid_requirements, requirements}}
    end
  end

  def spawn(requirements, fun) when is_map(requirements) and is_function(fun, 0) do
    case Application.fetch_env(:elixir_rpc, :authorized_nodes) do
      {:ok, authorized_nodes} ->
        child_spec = %{
          id: {:network_spawn, make_ref()},
          restart: :temporary,
          start: {Task, :start_link, [fun]}
        }

        start_child(requirements, child_spec,
          discovery: ElixirRpc.IrohDiscovery,
          authorized_nodes: authorized_nodes,
          timeout: Application.get_env(:elixir_rpc, :handoff_timeout, 5_000)
        )

      :error ->
        {:error, :network_not_configured}
    end
  end

  def spawn(_requirements, fun) when not is_function(fun, 0), do: {:error, :invalid_function}
  def spawn(requirements, _fun), do: {:error, {:invalid_requirements, requirements}}

  @doc "Starts a child on the first peer matching the capability requirements."
  @spec start_child(map(), Supervisor.child_spec(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_child(requirements, child_spec, opts) do
    discovery = Keyword.fetch!(opts, :discovery)
    authorized_nodes = Keyword.fetch!(opts, :authorized_nodes)
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, predicates} <- predicates(requirements),
         {:ok, peer} <- find_first(discovery, predicates),
         {:ok, node_name} <- authorize(peer, authorized_nodes),
         {:ok, peer_spec} <- peer_spec(peer, node_name),
         :ok <- join(peer_spec, peer["node_name"]),
         {:ok, pid} <- handoff(node_name, child_spec, timeout) do
      {:ok, pid}
    end
  end

  defp predicates(requirements) when is_map(requirements) do
    Enum.reduce_while(requirements, {:ok, []}, fn requirement, {:ok, predicates} ->
      case predicate(requirement) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | predicates]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp predicates(requirements), do: {:error, {:invalid_requirements, requirements}}

  defp predicate({name, value}) when is_boolean(value) or is_binary(value),
    do: named_predicate(name, "equals", value)

  defp predicate({name, {:at_least, value}}) when is_integer(value) and value >= 0,
    do: named_predicate(name, "at_least", value)

  defp predicate({name, {:contains, value}}) when is_binary(value),
    do: named_predicate(name, "contains", value)

  defp predicate(requirement), do: {:error, {:invalid_requirement, requirement}}

  defp named_predicate(name, operation, value) when is_atom(name) or is_binary(name) do
    {:ok, %{"op" => operation, "name" => to_string(name), "value" => value}}
  end

  defp named_predicate(name, _operation, _value), do: {:error, {:invalid_requirement_name, name}}

  defp find_first(discovery, predicates) do
    case Port.find(discovery, predicates) do
      {:ok, %{"peers" => [peer | _]}} when is_map(peer) -> {:ok, peer}
      {:ok, %{"peers" => []}} -> {:error, :no_matching_peer}
      {:ok, result} -> {:error, {:discovery_failed, {:invalid_result, result}}}
      {:error, "no_matching_peer"} -> {:error, :no_matching_peer}
      {:error, reason} -> {:error, {:discovery_failed, reason}}
    end
  end

  defp authorize(%{"node_name" => name}, authorized_nodes) when is_binary(name) do
    case Map.fetch(authorized_nodes, name) do
      {:ok, node_name} when is_atom(node_name) -> {:ok, node_name}
      _ -> {:error, {:unauthorized_node_name, name}}
    end
  end

  defp authorize(_peer, _authorized_nodes), do: {:error, :invalid_partisan_endpoint}

  defp peer_spec(
         %{"partisan_ip" => ip, "partisan_port" => port},
         node_name
       )
       when is_binary(ip) and is_integer(port) and port in 1..65_535 do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _} = address} ->
        {:ok, %{name: node_name, listen_addrs: [%{ip: address, port: port}]}}

      _ ->
        {:error, :invalid_partisan_endpoint}
    end
  end

  defp peer_spec(_peer, _node_name), do: {:error, :invalid_partisan_endpoint}

  defp join(peer_spec, advertised_name) do
    case connected?(peer_spec.name, advertised_name) do
      true -> :ok
      false -> normalize_join(:partisan_peer_service.join(peer_spec))
    end
  end

  defp connected?(node_name, advertised_name) do
    case :partisan_peer_service.members() do
      {:ok, members} ->
        Enum.any?(members, &(&1 == node_name or Atom.to_string(&1) == advertised_name))

      members when is_list(members) ->
        Enum.any?(members, &(&1 == node_name or Atom.to_string(&1) == advertised_name))

      _ ->
        false
    end
  end

  defp normalize_join(:ok), do: :ok
  defp normalize_join({:error, reason}), do: {:error, {:join_failed, reason}}
  defp normalize_join(result), do: {:error, {:join_failed, result}}

  defp handoff(node_name, child_spec, timeout) do
    case Handoff.start_child(node_name, child_spec, timeout) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:handoff_failed, reason}}
      result -> {:error, {:handoff_failed, result}}
    end
  end
end

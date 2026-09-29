defmodule ElixirRpc.TalkWorker do
  @moduledoc "Publishes this peer's capabilities and Partisan endpoint through Iroh."

  use GenServer

  alias ElixirRpc.IrohDiscovery.Port

  @publish_interval 3_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, start_options(name))
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec advertise(map(), GenServer.server()) :: Port.result()
  def advertise(capabilities, server \\ __MODULE__) when is_map(capabilities) do
    GenServer.call(server, {:advertise, capabilities}, :infinity)
  end

  @impl true
  def init(opts) do
    discovery = Keyword.get(opts, :discovery, ElixirRpc.IrohDiscovery)
    capabilities = Keyword.get(opts, :capabilities, %{"gpu" => true})
    interval = Keyword.get(opts, :publish_interval, @publish_interval)

    network_options = %{
      "dns" => true,
      "mdns" => true,
      "dht" => true,
      "relay" => true,
      "bootstrap_endpoint_ids" => Keyword.get(opts, :bootstrap_endpoint_ids, [])
    }

    case Port.network_start(discovery, network_options) do
      {:ok, network} ->
        case maybe_start_distribution(opts) do
          :ok ->
            send(self(), :publish)

            {:ok,
             %{
               discovery: discovery,
               capabilities: capabilities,
               interval: interval,
               network: network,
               publish_count: 0,
               last_publish: nil
             }}

          {:error, reason} ->
            {:stop, {:distribution_start_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:network_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:capabilities, :network, :publish_count, :last_publish]), state}
  end

  def handle_call({:advertise, capabilities}, _from, state) do
    {result, state} = publish(%{state | capabilities: capabilities})
    {:reply, result, state}
  end

  @impl true
  def handle_info(:publish, state) do
    {_result, state} = publish(state)
    Process.send_after(self(), :publish, state.interval)
    {:noreply, state}
  end

  defp publish(state) do
    {ip, port} = partisan_endpoint()

    result =
      Port.publish(state.discovery, %{
        "ttl_ms" => 60_000,
        "partisan_ip" => ip,
        "partisan_port" => port,
        "capabilities" => state.capabilities,
        "load" => %{"running" => 0, "capacity" => 1}
      })

    {result, %{state | publish_count: state.publish_count + 1, last_publish: result}}
  end

  defp partisan_endpoint do
    [%{ip: ip, port: port} | _] = :partisan_config.get(:listen_addrs)
    {advertised_ip(ip) |> :inet.ntoa() |> to_string(), port}
  end

  defp advertised_ip({0, 0, 0, 0}) do
    {:ok, interfaces} = :inet.getifaddrs()

    interfaces
    |> Enum.flat_map(fn {_name, attrs} -> Keyword.get_values(attrs, :addr) end)
    |> Enum.find(&routable_ipv4?/1)
    |> case do
      nil -> {127, 0, 0, 1}
      ip -> ip
    end
  end

  defp advertised_ip(ip), do: ip

  defp routable_ipv4?({127, _, _, _}), do: false
  defp routable_ipv4?({169, 254, _, _}), do: false
  defp routable_ipv4?({a, b, c, d}), do: Enum.all?([a, b, c, d], &(&1 in 0..255))
  defp routable_ipv4?(_ip), do: false

  defp start_options(nil), do: []
  defp start_options(name), do: [name: name]

  defp maybe_start_distribution(opts) do
    case Keyword.get(opts, :start_distribution, false) do
      true -> ElixirRpc.IrohDistribution.start()
      false -> :ok
    end
  end
end

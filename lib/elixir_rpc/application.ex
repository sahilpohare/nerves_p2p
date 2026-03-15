defmodule ElixirRpc.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Configure Partisan node name at runtime
    configure_partisan_node()

    children =
      [
        # Peer manager (integrates with Nerves mDNS discovery)
        ElixirRpc.PeerManager
        # Children for all targets
        # Starts a worker by calling: ElixirRpc.Worker.start_link(arg)
        # {ElixirRpc.Worker, arg},
      ] ++ target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElixirRpc.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp configure_partisan_node do
    # Get hostname for node name
    hostname = get_hostname()
    node_name = :"elixir_rpc@#{hostname}"

    # Update Partisan configuration with runtime node name
    :partisan_config.set(:name, node_name)

    # Log the configured node name
    require Logger
    Logger.info("Partisan configured with node name: #{inspect(node_name)}")
  end

  defp get_hostname do
    case Mix.target() do
      :host ->
        # Development mode - use localhost
        "127.0.0.1"

      _ ->
        # Nerves target - get hostname from system or use IP
        case :inet.gethostname() do
          {:ok, hostname} -> to_string(hostname)
          _ -> get_local_ip()
        end
    end
  end

  defp get_local_ip do
    # Get the first non-loopback IP address
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.find_value(fn {_ifname, opts} ->
          opts
          |> Enum.find_value(fn
            {:addr, {a, b, c, d}} when a != 127 -> "#{a}.#{b}.#{c}.#{d}"
            _ -> nil
          end)
        end) || "127.0.0.1"

      _ ->
        "127.0.0.1"
    end
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
      ]
    end
  end
end

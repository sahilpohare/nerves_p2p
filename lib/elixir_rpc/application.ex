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
        # Start libp2p Rust bridge first (provides P2P discovery and NAT traversal)
        ElixirRpc.Libp2pBridge,
        # Configure Partisan with libp2p port after bridge is ready
        %{
          id: :partisan_port_configurator,
          start: {Task, :start_link, [&configure_partisan_port/0]},
          restart: :temporary
        },
        # Update node name with PeerID once available
        %{
          id: :partisan_node_configurator,
          start: {Task, :start_link, [&configure_partisan_node_with_peer_id/0]},
          restart: :temporary
        }
        # Peer manager (integrates with libp2p discovery and Partisan mesh)
        # ElixirRpc.PeerManager
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
    require Logger

    # Wait for libp2p to be ready and get PeerID
    # We use a temporary node name first, then update it once we have the PeerID
    hostname = get_hostname()
    temp_node_name = :"temp_elixir_rpc@#{hostname}"

    # Set temporary node name
    :partisan_config.set(:name, temp_node_name)
    Logger.info("Partisan configured with temporary node name: #{inspect(temp_node_name)}")

    # Log the current listen addresses
    case :partisan_config.get(:listen_addrs) do
      [%{ip: ip, port: port} | _] ->
        Logger.info("Partisan using port: #{inspect(ip)}:#{port}")

      _ ->
        Logger.warning("Partisan listen addresses not configured")
    end
  end

  defp configure_partisan_port do
    require Logger

    # Wait for libp2p to be ready with listen addresses
    listen_addrs = wait_for_libp2p_port(10, 500)

    case parse_libp2p_port(listen_addrs) do
      {:ok, ip, port} ->
        # Update Partisan to use the libp2p-assigned port
        current_addrs = :partisan_config.get(:listen_addrs, [])

        case current_addrs do
          [%{port: current_port} | _] ->
            Logger.info(
              "Updating Partisan port from #{current_port} to libp2p-assigned port: #{inspect(ip)}:#{port}"
            )

          _ ->
            Logger.info("Setting Partisan to use libp2p port: #{inspect(ip)}:#{port}")
        end

        :partisan_config.set(:listen_addrs, [%{ip: ip, port: port}])

      {:error, reason} ->
        Logger.warning(
          "Failed to get libp2p port (#{reason}), keeping OS-assigned Partisan port"
        )
    end
  end

  defp configure_partisan_node_with_peer_id do
    require Logger

    # Wait for libp2p PeerID to be available
    peer_id = wait_for_peer_id(20, 500)

    case peer_id do
      nil ->
        Logger.warning("Failed to get libp2p PeerID, keeping temporary node name")

      peer_id when is_binary(peer_id) ->
        # Get IP address for node name
        ip = get_hostname()

        # Create node name in format: <peerid>@<ip>
        node_name = :"#{peer_id}@#{ip}"

        # Update Partisan configuration with PeerID-based node name
        :partisan_config.set(:name, node_name)
        Logger.info("Updated Partisan node name to: #{inspect(node_name)}")
    end
  end

  defp wait_for_peer_id(0, _delay) do
    nil
  end

  defp wait_for_peer_id(retries, delay) do
    case ElixirRpc.Libp2pBridge.get_peer_id() do
      nil ->
        Process.sleep(delay)
        wait_for_peer_id(retries - 1, delay)

      peer_id when is_binary(peer_id) ->
        peer_id

      _ ->
        Process.sleep(delay)
        wait_for_peer_id(retries - 1, delay)
    end
  end

  defp wait_for_libp2p_port(0, _delay), do: []

  defp wait_for_libp2p_port(retries, delay) do
    case ElixirRpc.Libp2pBridge.get_listen_addrs() do
      [] ->
        Process.sleep(delay)
        wait_for_libp2p_port(retries - 1, delay)

      addrs when is_list(addrs) ->
        addrs

      _ ->
        Process.sleep(delay)
        wait_for_libp2p_port(retries - 1, delay)
    end
  end

  defp parse_libp2p_port([]), do: {:error, :no_addresses}

  defp parse_libp2p_port([addr | rest]) do
    # Parse multiaddr format: /ip4/192.168.1.100/tcp/54321
    # or /ip6/::/tcp/54321
    case String.split(addr, "/", trim: true) do
      ["ip4", ip_str, "tcp", port_str] ->
        with {:ok, port} <- parse_port(port_str),
             {:ok, ip} <- parse_ipv4(ip_str) do
          {:ok, ip, port}
        else
          _ -> parse_libp2p_port(rest)
        end

      ["ip6", ip_str, "tcp", port_str] ->
        with {:ok, port} <- parse_port(port_str),
             {:ok, ip} <- parse_ipv6(ip_str) do
          {:ok, ip, port}
        else
          _ -> parse_libp2p_port(rest)
        end

      _ ->
        parse_libp2p_port(rest)
    end
  end

  defp parse_port(port_str) do
    case Integer.parse(port_str) do
      {port, ""} when port > 0 and port <= 65535 -> {:ok, port}
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_ipv4(ip_str) do
    case ip_str |> String.split(".") |> Enum.map(&Integer.parse/1) do
      [{a, ""}, {b, ""}, {c, ""}, {d, ""}]
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 ->
        {:ok, {a, b, c, d}}

      _ ->
        {:error, :invalid_ipv4}
    end
  end

  defp parse_ipv6(ip_str) do
    case :inet.parse_address(to_charlist(ip_str)) do
      {:ok, {_, _, _, _, _, _, _, _} = ipv6} -> {:ok, ipv6}
      _ -> {:error, :invalid_ipv6}
    end
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
        # Advertise Partisan service via mDNS (Nerves targets only)
        ElixirRpc.MdnsAdvertiser
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
      ]
    end
  end
end

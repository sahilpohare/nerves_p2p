defmodule ElixirRpc.PartisanConfig do
  @moduledoc """
  Configuration and management utilities for Partisan P2P mesh networking.

  This module provides functions to:
  - Join peers to the mesh network
  - Query membership information
  - Configure peer service settings
  - Handle peer discovery via mDNS
  """

  require Logger

  @doc """
  Sets a temporary Partisan node name on startup.
  """
  def configure_node do
    peer_id = ElixirRpc.Libp2pBridge.get_peer_id() || "node#{:erlang.unique_integer([:positive])}"
    hostname = get_hostname()
    node_name = :"#{peer_id}@#{hostname}"

    case :net_kernel.start([node_name, :longnames]) do
      {:ok, _} -> Logger.info("Node started: #{inspect(node_name)}")
      {:error, {:already_started, _}} ->
        :net_kernel.stop()
        :net_kernel.start([node_name, :longnames])
        Logger.info("Node restarted: #{inspect(node_name)}")
      {:error, reason} ->
        Logger.warning("Failed to start net_kernel: #{inspect(reason)}")
    end

    :partisan_config.set(:name, node_name)
    Logger.info("Partisan node name set to: #{inspect(node_name)}")

    # Allow PARTISAN_PORT env var to override the compiled-in port so
    # multiple nodes can run on the same machine.
    port =
      case System.get_env("PARTISAN_PORT") do
        nil -> nil
        p -> String.to_integer(p)
      end

    if port do
      :partisan_config.set(:listen_addrs, [%{ip: {127, 0, 0, 1}, port: port}])
      Logger.info("Partisan runtime config: node=#{node_name} port=#{port}")
    else
      case :partisan_config.get(:listen_addrs) do
        [%{ip: ip, port: p} | _] -> Logger.info("Partisan runtime config: node=#{node_name} port=#{inspect(ip)}:#{p}")
        _ -> Logger.warning("Partisan listen addresses not configured")
      end
    end
  end

  @doc """
  Waits for the libp2p bridge to report a listen address and updates Partisan's port.
  Intended to run in a temporary supervised Task.
  """
  def configure_port do
    case wait_for_libp2p_port(10, 500) |> parse_libp2p_port() do
      {:ok, ip, port} ->
        case :partisan_config.get(:listen_addrs, []) do
          [%{port: current} | _] ->
            Logger.info("Updating Partisan port from #{current} to #{inspect(ip)}:#{port}")
          _ ->
            Logger.info("Setting Partisan to use libp2p port: #{inspect(ip)}:#{port}")
        end
        :partisan_config.set(:listen_addrs, [%{ip: ip, port: port}])

      {:error, reason} ->
        Logger.warning("Failed to get libp2p port (#{reason}), keeping OS-assigned Partisan port")
    end
  end

  @doc """
  Waits for the libp2p PeerID and updates the Partisan node name.
  Intended to run in a temporary supervised Task.
  """
  def configure_node_with_peer_id do
    case wait_for_peer_id(20, 500) do
      nil ->
        Logger.warning("Failed to get libp2p PeerID, keeping temporary node name")

      peer_id ->
        node_name = :"#{peer_id}@#{get_hostname()}"
        :partisan_config.set(:name, node_name)
        Logger.info("Updated Partisan node name to: #{inspect(node_name)}")
    end
  end

  @doc """
  Join a peer to the Partisan mesh network.

  ## Parameters
  - `peer_spec`: A map with `:listen_addrs` and `:name` keys, or a node name atom

  ## Examples

      # Join using peer specification
      join_peer(%{
        name: :"elixir_rpc@192.168.1.100",
        listen_addrs: [%{ip: {192, 168, 1, 100}, port: 10200}]
      })

      # Join using node name (will use default port 10200)
      join_peer(:"elixir_rpc@192.168.1.100")
  """
  def join_peer(peer_spec) when is_map(peer_spec) do
    case :partisan_peer_service.join(peer_spec) do
      :ok ->
        Logger.info("Successfully joined peer: #{inspect(peer_spec.name)}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to join peer #{inspect(peer_spec.name)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def join_peer(node_name) when is_atom(node_name) do
    # Extract IP from node name (assumes format: name@ip)
    ip_str = node_name |> to_string() |> String.split("@") |> List.last()
    ip = parse_ip(ip_str)

    peer_spec = %{
      name: node_name,
      listen_addrs: [%{ip: ip, port: 10200}]
    }

    join_peer(peer_spec)
  end

  @doc """
  Get list of all members in the Partisan cluster.

  Returns a list of peer specifications.
  """
  def members do
    case :partisan_peer_service.members() do
      {:ok, members} when is_list(members) -> members
      members when is_list(members) -> members
      _ -> []
    end
  end

  @doc """
  Get the current node's Partisan name.
  """
  def node_name do
    :partisan_config.get(:name)
  end

  @doc """
  Check if a peer is currently connected.
  """
  def connected?(peer_name) do
    members() |> Enum.member?(peer_name)
  end

  @doc """
  Leave a peer from the mesh network.
  """
  def leave_peer(peer_spec) when is_map(peer_spec) do
    :partisan_peer_service.leave(peer_spec)
  end

  def leave_peer(node_name) when is_atom(node_name) do
    if Enum.member?(members(), node_name) do
      :partisan_peer_service.leave(node_name)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Send a message to a peer using Partisan's forward_message.

  This bypasses Distributed Erlang and uses Partisan's overlay network.
  """
  def send_message(peer_name, message) do
    :partisan_peer_service.message(
      peer_name,
      message,
      []
    )
  end

  @doc """
  Broadcast a message to all members using Partisan's broadcast tree.
  """
  def broadcast(message, opts \\ []) do
    :partisan_plumtree_broadcast.broadcast(message, opts)
  end

  @doc """
  Get current Partisan configuration.
  """
  def get_config(key) do
    :partisan_config.get(key)
  end

  @doc """
  Set Partisan configuration at runtime.
  """
  def set_config(key, value) do
    :partisan_config.set(key, value)
  end

  @doc """
  Parse IP address string into tuple format.

  ## Examples

      iex> ElixirRpc.PartisanConfig.parse_ip("192.168.1.100")
      {192, 168, 1, 100}

      iex> ElixirRpc.PartisanConfig.parse_ip("127.0.0.1")
      {127, 0, 0, 1}
  """
  def parse_ip(ip_str) when is_binary(ip_str) do
    ip_str
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  @doc """
  Discover peers on the local network using mDNS.

  This function queries for Partisan services advertised via mDNS
  and returns a list of discovered peers.

  Note: Requires mdns_lite to be running (enabled on Nerves targets).
  """
  def discover_mdns_peers do
    if Mix.target() == :host do
      Logger.warning("mDNS discovery not available in host mode")
      []
    else
      # Query for partisan services
      # This is a placeholder - actual implementation would use mdns_lite query
      Logger.info("Discovering peers via mDNS...")
      []
    end
  end

  @doc """
  Get connection statistics for the current node.
  """
  def connection_stats do
    %{
      node: node_name(),
      members: length(members()),
      connections: get_connections()
    }
  end

  defp get_connections do
    case :partisan_peer_connections.connections() do
      connections when is_list(connections) -> length(connections)
      _ -> 0
    end
  end

  defp wait_for_peer_id(0, _delay), do: nil

  defp wait_for_peer_id(retries, delay) do
    case ElixirRpc.Libp2pBridge.get_peer_id() do
      peer_id when is_binary(peer_id) -> peer_id
      _ ->
        Process.sleep(delay)
        wait_for_peer_id(retries - 1, delay)
    end
  end

  defp wait_for_libp2p_port(0, _delay), do: []

  defp wait_for_libp2p_port(retries, delay) do
    case ElixirRpc.Libp2pBridge.get_listen_addrs() do
      addrs when is_list(addrs) and addrs != [] -> addrs
      _ ->
        Process.sleep(delay)
        wait_for_libp2p_port(retries - 1, delay)
    end
  end

  defp parse_libp2p_port([]), do: {:error, :no_addresses}

  defp parse_libp2p_port([addr | rest]) do
    case String.split(addr, "/", trim: true) do
      ["ip4", ip_str, "tcp", port_str] ->
        with {:ok, port} <- parse_port(port_str),
             {:ok, ip} <- parse_ipv4(ip_str),
             do: {:ok, ip, port},
             else: (_ -> parse_libp2p_port(rest))

      ["ip6", ip_str, "tcp", port_str] ->
        with {:ok, port} <- parse_port(port_str),
             {:ok, ip} <- parse_ipv6(ip_str),
             do: {:ok, ip, port},
             else: (_ -> parse_libp2p_port(rest))

      _ ->
        parse_libp2p_port(rest)
    end
  end

  defp parse_port(port_str) do
    case Integer.parse(port_str) do
      {port, ""} when port in 1..65535 -> {:ok, port}
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
        "127.0.0.1"

      _ ->
        case :inet.gethostname() do
          {:ok, hostname} -> to_string(hostname)
          _ -> get_local_ip()
        end
    end
  end

  defp get_local_ip do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        Enum.find_value(ifaddrs, "127.0.0.1", fn {_ifname, opts} ->
          Enum.find_value(opts, fn
            {:addr, {a, b, c, d}} when a != 127 -> "#{a}.#{b}.#{c}.#{d}"
            _ -> nil
          end)
        end)

      _ ->
        "127.0.0.1"
    end
  end
end

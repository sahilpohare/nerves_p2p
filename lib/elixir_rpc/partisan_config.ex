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
    :partisan_peer_service.members()
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
    members() |> Enum.any?(fn peer -> peer.name == peer_name end)
  end

  @doc """
  Leave a peer from the mesh network.
  """
  def leave_peer(peer_spec) when is_map(peer_spec) do
    :partisan_peer_service.leave(peer_spec)
  end

  def leave_peer(node_name) when is_atom(node_name) do
    members()
    |> Enum.find(fn peer -> peer.name == node_name end)
    |> case do
      nil -> {:error, :not_found}
      peer -> leave_peer(peer)
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
    # Get active connections from Partisan
    case :partisan_peer_connections.connections() do
      connections when is_list(connections) -> length(connections)
      _ -> 0
    end
  end
end

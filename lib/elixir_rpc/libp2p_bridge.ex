defmodule ElixirRpc.Libp2pBridge do
  @moduledoc """
  Compatibility shim for legacy callers that predate the NIF-based P2P stack.

  All operations delegate to `ElixirRpc.P2P.Node` (the default node registered
  as `ElixirRpc.Node`). This module is intentionally NOT a GenServer — it is a
  thin function wrapper so that `PartisanConfig` and `PeerManager` continue to
  compile and run without modification.
  """

  alias ElixirRpc.{P2P.Node, PeerId}

  @node ElixirRpc.Node

  @doc "Get the local libp2p PeerID string, or nil if node not started."
  def get_peer_id do
    case Node.peer_id(@node) do
      {:ok, %PeerId{id: id}} -> id
      _ -> nil
    end
  end

  @doc "Get current listen addresses as multiaddr strings."
  def get_listen_addrs do
    case Node.listening_addrs(@node) do
      {:ok, addrs} -> addrs
      _ -> []
    end
  end

  @doc "Dial a peer by multiaddr string."
  def dial(multiaddr) when is_binary(multiaddr) do
    Node.dial(@node, multiaddr)
  end

  @doc "Get list of connected peer ID strings."
  def get_connected_peers do
    case Node.connected_peers(@node) do
      {:ok, peers} -> Enum.map(peers, &PeerId.to_string/1)
      _ -> []
    end
  end

  @doc """
  Get discovered peers from mDNS.

  Peers arrive asynchronously via `{:libp2p, :peer_discovered, event}` messages
  to registered handlers. PeerManager subscribes to those events directly and
  maintains the list. This function returns an empty list — callers that need
  discovered peers should use `ElixirRpc.PeerManager.discovered_peers/0` or
  register a handler via `ElixirRpc.P2P.Discovery.register_handler/1`.
  """
  def get_discovered_peers, do: []
end

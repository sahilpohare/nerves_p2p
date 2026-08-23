defmodule ElixirRpc.Rendezvous do
  @moduledoc """
  Rendezvous protocol for namespace-based peer discovery.

  Unlike mDNS (local network only) or DHT (global but slower), rendezvous
  provides fast, targeted discovery through a known rendezvous point.

  ## Usage

      :ok = ElixirRpc.Rendezvous.register(node, "my-service", rendezvous_peer, 3600)
      :ok = ElixirRpc.Rendezvous.discover(node, "my-service", rendezvous_peer)

      # Results arrive as {:libp2p, :peer_discovered, %PeerDiscovered{}} events

      :ok = ElixirRpc.Rendezvous.unregister(node, "my-service", rendezvous_peer)

  ## Configuration

      ElixirRpc.P2P.Node.start_link(
        enable_rendezvous_client: true,
        enable_rendezvous_server: true
      )

  """

  alias ElixirRpc.{P2P.Node, PeerId}

  import ElixirRpc.Call, only: [safe_call: 2]

  @spec register(GenServer.server(), String.t(), PeerId.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def register(node, namespace, %PeerId{id: peer_str}, ttl_secs \\ 3600)
      when is_binary(namespace) do
    safe_call(node, {:rendezvous_register, namespace, ttl_secs, peer_str})
  end

  @spec discover(GenServer.server(), String.t(), PeerId.t()) :: :ok | {:error, term()}
  def discover(node, namespace, %PeerId{id: peer_str}) when is_binary(namespace) do
    safe_call(node, {:rendezvous_discover, namespace, peer_str})
  end

  @spec unregister(GenServer.server(), String.t(), PeerId.t()) :: :ok | {:error, term()}
  def unregister(node, namespace, %PeerId{id: peer_str}) when is_binary(namespace) do
    safe_call(node, {:rendezvous_unregister, namespace, peer_str})
  end

  @spec register_handler(GenServer.server(), pid()) :: :ok
  def register_handler(node, pid \\ self()) do
    Node.register_handler(node, :peer_discovered, pid)
  end
end

defmodule ElixirRpc.P2P.Discovery do
  @moduledoc """
  Low-level peer discovery via mDNS and bootstrap peers.

  mDNS discovers peers on the local network automatically when `enable_mdns: true`
  in the node config. Bootstrap peers provide initial DHT connectivity for
  wide-area networks.

  For the higher-level capability-based discovery coordinator, see
  `ElixirRpc.Discovery`.

  ## Usage

      :ok = ElixirRpc.P2P.Discovery.register_handler(node)
      :ok = ElixirRpc.P2P.Discovery.bootstrap(node, [
        "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYER..."
      ])

      # Discovered peers arrive as:
      # {:libp2p, :peer_discovered, %ElixirRpc.P2P.Node.Event.PeerDiscovered{}}

  """

  alias ElixirRpc.P2P.Node

  import ElixirRpc.Call, only: [safe_call: 2]

  @spec register_handler(GenServer.server(), pid()) :: :ok
  def register_handler(node, pid \\ self()),
    do: Node.register_handler(node, :peer_discovered, pid)

  @spec bootstrap(GenServer.server(), [String.t()]) ::
          :ok | {:ok, [dial_result]} | {:error, term()}
        when dial_result: :ok | {:error, term()}
  def bootstrap(_node, []), do: :ok

  def bootstrap(node, peer_addrs) when is_list(peer_addrs) do
    dial_results = Enum.map(peer_addrs, &Node.dial(node, &1))

    case safe_call(node, :dht_bootstrap) do
      :ok -> {:ok, dial_results}
      {:error, _} = error -> error
    end
  end

  def bootstrap(_node, _bad), do: {:error, :invalid_peer_addrs}
end

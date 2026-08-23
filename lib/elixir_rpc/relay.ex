defmodule ElixirRpc.Relay do
  @moduledoc """
  Circuit Relay v2 for NAT traversal.

  ## Usage

      :ok = ElixirRpc.Relay.listen_via_relay(node, "/ip4/relay.example.com/tcp/4001/p2p/QmRelay...")
      :ok = ElixirRpc.Relay.register_handler(node)

      # Events:
      # {:libp2p, :relay_reservation_accepted, %ElixirRpc.P2P.Node.Event.RelayReservationAccepted{}}
      # {:libp2p, :hole_punch_outcome, %ElixirRpc.P2P.Node.Event.HolePunchOutcome{}}

  ## Configuration

      ElixirRpc.P2P.Node.start_link(
        enable_relay: true,
        enable_relay_server: true
      )

  """

  alias ElixirRpc.P2P.Node

  import ElixirRpc.Call, only: [safe_call: 2]

  @spec listen_via_relay(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def listen_via_relay(node, relay_addr) when is_binary(relay_addr) do
    safe_call(node, {:listen_via_relay, relay_addr})
  end

  @spec register_handler(GenServer.server(), pid()) :: :ok
  def register_handler(node, pid \\ self()) do
    :ok = Node.register_handler(node, :nat_status_changed, pid)
    :ok = Node.register_handler(node, :relay_reservation_accepted, pid)
    :ok = Node.register_handler(node, :hole_punch_outcome, pid)
    Node.register_handler(node, :external_addr_confirmed, pid)
  end
end

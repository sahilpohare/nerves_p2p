defmodule ElixirRpc.P2P.Node.NetworkOps do
  @moduledoc false
  # Connection-management handle_call/3 clauses extracted from ElixirRpc.P2P.Node.

  alias ElixirRpc.P2P.Node.Result
  alias ElixirRpc.PeerId

  @spec handles?(term()) :: boolean()
  def handles?(:peer_id), do: true
  def handles?(:connected_peers), do: true
  def handles?(:listening_addrs), do: true
  def handles?({:dial, _}), do: true
  def handles?({:listen_via_relay, _}), do: true
  def handles?(_), do: false

  @spec handle(term(), GenServer.from(), ElixirRpc.P2P.Node.t()) ::
          {:reply, term(), ElixirRpc.P2P.Node.t()}
  def handle(:peer_id, _from, state) do
    {:reply, {:ok, state.peer_id}, state}
  end

  def handle(:connected_peers, _from, state) do
    peers = Enum.map(state.native.connected_peers(state.handle), &PeerId.new!/1)
    {:reply, {:ok, peers}, state}
  end

  def handle(:listening_addrs, _from, state) do
    {:reply, {:ok, state.native.listening_addrs(state.handle)}, state}
  end

  def handle({:dial, addr}, _from, state) do
    result = Result.normalize_ok(state.native.dial(state.handle, addr))
    {:reply, result, state}
  end

  def handle({:listen_via_relay, relay_addr}, _from, state) do
    result = state.native.listen_via_relay(state.handle, relay_addr)
    {:reply, result, state}
  end
end

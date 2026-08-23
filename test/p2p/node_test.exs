defmodule ElixirRpc.P2P.NodeTest do
  use ExUnit.Case, async: true

  alias ElixirRpc.P2P.Node
  alias ElixirRpc.PeerId

  setup do
    {:ok, node} = Node.start_link(native_module: ElixirRpc.P2P.Native.Mock)

    on_exit(fn ->
      try do
        if Process.alive?(node), do: Node.stop(node)
      catch
        :exit, _ -> :ok
      end
    end)

    %{node: node}
  end

  test "peer_id returns a PeerId struct", %{node: node} do
    assert {:ok, %PeerId{} = peer_id} = Node.peer_id(node)
    assert String.length(PeerId.to_string(peer_id)) > 0
  end

  test "connected_peers returns empty list initially", %{node: node} do
    assert {:ok, []} = Node.connected_peers(node)
  end

  test "listening_addrs returns at least one address", %{node: node} do
    assert {:ok, [_ | _]} = Node.listening_addrs(node)
  end

  test "publish returns :ok", %{node: node} do
    assert :ok = Node.publish(node, "test-topic", "hello")
  end

  test "subscribe / unsubscribe return :ok", %{node: node} do
    assert :ok = Node.subscribe(node, "test-topic")
    assert :ok = Node.unsubscribe(node, "test-topic")
  end

  test "dial returns :ok", %{node: node} do
    assert :ok = Node.dial(node, "/ip4/127.0.0.1/tcp/1234")
  end

  test "dht_bootstrap returns :ok", %{node: node} do
    assert :ok = Node.dht_bootstrap(node)
  end

  test "send_request returns {:ok, request_id}", %{node: node} do
    {:ok, peer_id} = Node.peer_id(node)
    assert {:ok, req_id} = Node.send_request(node, peer_id, "ping")
    assert is_binary(req_id)
  end

  test "safe_call returns error when node is dead" do
    {:ok, node} = Node.start_link(native_module: ElixirRpc.P2P.Native.Mock)
    Node.stop(node)
    assert {:error, {:node_unavailable, _}} = Node.peer_id(node)
  end
end

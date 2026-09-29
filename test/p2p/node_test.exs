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

  test "P[a node is running] C[request peer ID] Q[a PeerId struct returns]", %{node: node} do
    assert {:ok, %PeerId{} = peer_id} = Node.peer_id(node)
    assert String.length(PeerId.to_string(peer_id)) > 0
  end

  test "P[a new node has no connections] C[list peers] Q[the result is empty]", %{node: node} do
    assert {:ok, []} = Node.connected_peers(node)
  end

  test "P[a node is listening] C[list addresses] Q[at least one address returns]", %{node: node} do
    assert {:ok, [_ | _]} = Node.listening_addrs(node)
  end

  test "P[a node is running] C[publish a topic] Q[ok returns]", %{node: node} do
    assert :ok = Node.publish(node, "test-topic", "hello")
  end

  test "P[a node is running] C[subscribe then unsubscribe] Q[both operations return ok]", %{
    node: node
  } do
    assert :ok = Node.subscribe(node, "test-topic")
    assert :ok = Node.unsubscribe(node, "test-topic")
  end

  test "P[a peer address is valid] C[dial the peer] Q[ok returns]", %{node: node} do
    assert :ok = Node.dial(node, "/ip4/127.0.0.1/tcp/1234")
  end

  test "P[a node is running] C[bootstrap the DHT] Q[ok returns]", %{node: node} do
    assert :ok = Node.dht_bootstrap(node)
  end

  test "P[a request target is valid] C[send a request] Q[a request ID returns]", %{node: node} do
    {:ok, peer_id} = Node.peer_id(node)
    assert {:ok, req_id} = Node.send_request(node, peer_id, "ping")
    assert is_binary(req_id)
  end

  test "P[a node process is dead] C[perform a safe call] Q[an error returns]" do
    {:ok, node} = Node.start_link(native_module: ElixirRpc.P2P.Native.Mock)
    Node.stop(node)
    assert {:error, {:node_unavailable, _}} = Node.peer_id(node)
  end
end

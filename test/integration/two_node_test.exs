defmodule ElixirRpc.Integration.TwoNodeTest do
  @moduledoc """
  Integration tests using two real libp2p P2P.Node instances within the same
  BEAM, connected over loopback TCP. No mocks — the Rust NIF runs for real.

  node1 = ElixirRpc.Node (started by the application supervisor)
  node2 = a second P2P.Node started per-test, unnamed

  Tests:
  1. Auto-discovery: node2 dials node1; both receive connection_established.
  2. Messaging: OTP.Distribution.call/cast/send across the two nodes.
  3. Tasks: CapabilityRPC.Server on node2 executes functions dispatched from node1.
  """

  use ExUnit.Case, async: false

  alias ElixirRpc.P2P.Node
  alias ElixirRpc.P2P.Node.Event
  alias ElixirRpc.{PeerId, OTP.Distribution, OTP.Distribution.Server}

  @connect_timeout 5_000
  @rpc_timeout 8_000

  defp node1, do: ElixirRpc.Node

  defp start_node2 do
    Node.start_link(listen_addrs: ["/ip4/127.0.0.1/tcp/0"])
  end

  defp tcp_listen_addrs(node) do
    {:ok, addrs} = Node.listening_addrs(node)
    Enum.filter(addrs, &String.starts_with?(&1, "/ip4/127.0.0.1/tcp/"))
  end

  defp subscribe(node, event_type) do
    Node.register_handler(node, event_type, self())
  end

  # Connect node2 → node1, wait for connection_established on node1.
  defp connect(node2) do
    subscribe(node1(), :connection_established)
    [addr | _] = tcp_listen_addrs(node1())
    :ok = Node.dial(node2, addr)
    assert_receive {:libp2p, :connection_established, _ev}, @connect_timeout
    :ok
  end

  # -------------------------------------------------------------------------
  # 1. Connection
  # -------------------------------------------------------------------------

  describe "peer connection" do
    setup do
      {:ok, node2} = start_node2()
      on_exit(fn -> catch_exit(Node.stop(node2)) end)
      %{node2: node2}
    end

    test "P[two nodes are listening] C[node2 dials node1] Q[both report the connection]", %{
      node2: node2
    } do
      {:ok, peer1_id} = Node.peer_id(node1())
      {:ok, peer2_id} = Node.peer_id(node2)
      peer1_str = PeerId.to_string(peer1_id)
      peer2_str = PeerId.to_string(peer2_id)

      subscribe(node1(), :connection_established)
      subscribe(node2, :connection_established)

      [addr1 | _] = tcp_listen_addrs(node1())
      :ok = Node.dial(node2, addr1)

      # Collect two connection_established events (one from each node's subscription)
      events =
        for _ <- 1..2 do
          receive do
            {:libp2p, :connection_established, %Event.ConnectionEstablished{} = ev} -> ev
          after
            @connect_timeout -> flunk("Timed out waiting for connection_established")
          end
        end

      seen_ids = Enum.map(events, &PeerId.to_string(&1.peer_id)) |> MapSet.new()

      assert MapSet.member?(seen_ids, peer1_str) or MapSet.member?(seen_ids, peer2_str),
             "Neither peer ID seen in events. seen=#{inspect(seen_ids)} peer1=#{peer1_str} peer2=#{peer2_str}"

      # node2 lists node1 as connected
      {:ok, peers2} = Node.connected_peers(node2)

      assert Enum.any?(peers2, &(PeerId.to_string(&1) == peer1_str)),
             "node2 does not list node1 in connected peers: #{inspect(peers2)}"
    end
  end

  # -------------------------------------------------------------------------
  # 2. Messaging
  # -------------------------------------------------------------------------

  describe "OTP distribution messaging" do
    setup do
      {:ok, node2} = start_node2()
      {:ok, peer2_id} = Node.peer_id(node2)

      # Distribution.Server for node2; node1's is already running in the app.
      {:ok, dist_srv2} = Server.start_link(node: node2)

      on_exit(fn ->
        catch_exit(Node.stop(node2))
        catch_exit(GenServer.stop(dist_srv2))
      end)

      connect(node2)
      %{node2: node2, peer2_id: peer2_id}
    end

    test "P[a remote GenServer is registered] C[call it from node1] Q[its result returns]", %{
      peer2_id: peer2_id
    } do
      name = :"ping_server_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(ElixirRpc.Integration.EchoServer, :ready, name: name)
      on_exit(fn -> catch_exit(GenServer.stop(pid)) end)

      result = Distribution.call(node1(), peer2_id, name, :ping, @rpc_timeout)
      assert {:ok, {:pong, :ready}} = result
    end

    test "P[a remote GenServer is registered] C[cast from node1] Q[remote state updates]", %{
      peer2_id: peer2_id
    } do
      name = :"cast_target_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(ElixirRpc.Integration.EchoServer, [], name: name)
      on_exit(fn -> catch_exit(GenServer.stop(pid)) end)

      :ok = Distribution.cast(node1(), peer2_id, name, {:push, :hello})

      Process.sleep(300)
      assert :hello in GenServer.call(pid, :state)
    end

    test "P[a remote process is registered] C[send a bare message] Q[the process receives it]", %{
      peer2_id: peer2_id
    } do
      test_pid = self()
      name = :"receiver_#{System.unique_integer([:positive])}"

      {:ok, receiver} =
        Task.start(fn ->
          receive do
            {:ping, payload} -> send(test_pid, {:pong, payload})
          after
            @rpc_timeout -> :ok
          end
        end)

      Process.register(receiver, name)

      on_exit(fn ->
        if Process.alive?(receiver), do: catch_exit(Process.unregister(name))
      end)

      Distribution.send(node1(), peer2_id, name, {:ping, :integration_data})

      assert_receive {:pong, :integration_data}, @rpc_timeout
    end
  end

  # -------------------------------------------------------------------------
  # 3. Tasks — CapabilityRPC.Server executes functions on the remote node
  # -------------------------------------------------------------------------

  describe "remote function execution via CapabilityRPC.Server" do
    setup do
      {:ok, node2} = start_node2()
      {:ok, peer2_id} = Node.peer_id(node2)

      # Use a unique name so it doesn't conflict with the app-level server
      cap_name = :"cap_server_#{System.unique_integer([:positive])}"
      {:ok, cap_srv} = GenServer.start_link(ElixirRpc.CapabilityRPC.Server, [], name: cap_name)

      {:ok, dist_srv2} = Server.start_link(node: node2)

      on_exit(fn ->
        catch_exit(Node.stop(node2))
        catch_exit(GenServer.stop(cap_srv))
        catch_exit(GenServer.stop(dist_srv2))
      end)

      connect(node2)
      %{node2: node2, peer2_id: peer2_id, cap_name: cap_name}
    end

    test "P[String is available remotely] C[apply upcase on node2] Q[the result returns to node1]",
         %{peer2_id: peer2_id, cap_name: cap_name} do
      result =
        Distribution.call(
          node1(),
          peer2_id,
          cap_name,
          {:apply, String, :upcase, ["hello"]},
          @rpc_timeout
        )

      assert {:ok, {:ok, "HELLO"}} = result
    end

    test "P[arithmetic is available remotely] C[execute a task] Q[the correct result returns]",
         %{peer2_id: peer2_id, cap_name: cap_name} do
      result =
        Distribution.call(
          node1(),
          peer2_id,
          cap_name,
          {:apply, Kernel, :+, [40, 2]},
          @rpc_timeout
        )

      assert {:ok, {:ok, 42}} = result
    end

    test "P[a module is unknown remotely] C[call the module] Q[an error tuple returns]",
         %{peer2_id: peer2_id, cap_name: cap_name} do
      result =
        Distribution.call(
          node1(),
          peer2_id,
          cap_name,
          {:apply, NonExistent.Module, :fun, []},
          @rpc_timeout
        )

      assert {:ok, {:error, _reason}} = result
    end

    test "P[a remote node remains connected] C[run sequential tasks] Q[every task succeeds]",
         %{peer2_id: peer2_id, cap_name: cap_name} do
      results =
        for n <- 1..5 do
          Distribution.call(
            node1(),
            peer2_id,
            cap_name,
            {:apply, Kernel, :*, [n, n]},
            @rpc_timeout
          )
        end

      values = Enum.map(results, fn {:ok, {:ok, v}} -> v end)
      assert values == [1, 4, 9, 16, 25]
    end
  end
end

# ---------------------------------------------------------------------------
# Simple GenServer used as a test target for OTP distribution calls
# ---------------------------------------------------------------------------

defmodule ElixirRpc.Integration.EchoServer do
  use GenServer

  def init(state), do: {:ok, state}

  def handle_call(:ping, _from, state), do: {:reply, {:pong, state}, state}
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_cast({:push, item}, state) when is_list(state), do: {:noreply, [item | state]}
  def handle_cast(_, state), do: {:noreply, state}
end

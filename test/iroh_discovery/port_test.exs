defmodule ElixirRpc.IrohDiscovery.PortTest do
  use ExUnit.Case, async: true

  alias ElixirRpc.IrohDiscovery.Port

  @fake Path.expand("../support/fake_iroh_discovery_port.script", __DIR__)

  setup_all do
    File.chmod!(@fake, 0o755)
    :ok
  end

  test "P[two daemon requests are pending] C[responses arrive reversed] Q[IDs correlate each response]" do
    port = start_port("correlation")

    first = Task.async(fn -> Port.identity(port) end)
    second = Task.async(fn -> Port.find(port, []) end)

    assert {:ok, %{"command" => "identity"}} = Task.await(first)
    assert {:ok, %{"command" => "find"}} = Task.await(second)
  end

  test "P[authorize and network requests are valid] C[send both concurrently] Q[payloads and responses correlate]" do
    port = start_port("correlation")
    bootstrap = %{"endpoint_id" => "bootstrap-id", "direct_addresses" => ["10.0.0.1:4040"]}

    authorization = Task.async(fn -> Port.authorize(port, "peer-id", "peer@fleet.local") end)
    network = Task.async(fn -> Port.network_start(port, bootstrap) end)

    assert {:ok,
            %{
              "authorized" => true,
              "request" => %{
                "command" => "authorize",
                "endpoint_id" => "peer-id",
                "node_name" => "peer@fleet.local"
              }
            }} = Task.await(authorization)

    assert {:ok,
            %{
              "endpoint_address" => %{
                "endpoint_id" => "fake-endpoint",
                "direct_addresses" => ["127.0.0.1:4040"]
              },
              "request" => %{
                "command" => "network_start",
                "bootstrap" => ^bootstrap
              }
            }} = Task.await(network)
  end

  test "P[network options are valid] C[start the network] Q[all options pass through unchanged]" do
    port = start_port("normal")

    options = %{
      "bootstrap_endpoint_ids" => ["first", "second"],
      "dns" => true,
      "mdns" => true,
      "dht" => true,
      "relay" => true
    }

    assert {:ok, %{"request" => request}} = Port.network_start(port, options)
    assert Map.drop(request, ["command", "id"]) == options
  end

  test "P[the daemon has an identity] C[request identity] Q[endpoint ID and address return]" do
    port = start_port("normal")

    assert {:ok,
            %{
              "endpoint_id" => "fake-endpoint",
              "endpoint_address" => %{
                "endpoint_id" => "fake-endpoint",
                "direct_addresses" => ["127.0.0.1:4040"]
              }
            }} = Port.identity(port)
  end

  test "P[the daemon emits malformed JSON] C[continue requesting] Q[the client remains alive]" do
    port = start_port("malformed")

    assert {:ok, %{"command" => "identity"}} = Port.identity(port)
    assert Process.alive?(port)
    assert {:ok, %{"command" => "find"}} = Port.find(port)
  end

  test "P[a subscriber and requests exist] C[interleave events and responses] Q[events broadcast and requests correlate]" do
    port = start_port("events")
    assert :ok = Port.subscribe(port)

    first = Task.async(fn -> Port.identity(port) end)

    assert_receive {:iroh_dist,
                    %{
                      "event" => "dist_incoming",
                      "stream_id" => 7,
                      "from_node" => "a@local",
                      "target_node" => "b@local"
                    }},
                   5_000

    second = Task.async(fn -> Port.find(port) end)

    assert {:ok, %{"command" => "find"}} = Task.await(second)

    assert_receive {:iroh_dist, %{"event" => "dist_credit", "stream_id" => 7, "bytes" => 3}},
                   5_000

    assert {:ok, %{"command" => "identity"}} = Task.await(first)
  end

  test "P[live and dead subscribers exist] C[unsubscribe and emit events] Q[delivery stops and dead entries disappear]" do
    port = start_port("events")
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
    death_monitor = Process.monitor(subscriber)

    assert :ok = Port.subscribe(port, subscriber)
    assert %{^subscriber => monitor} = :sys.get_state(port).subscribers
    assert is_reference(monitor)

    send(subscriber, :stop)
    assert_receive {:DOWN, ^death_monitor, :process, ^subscriber, :normal}
    assert eventually(fn -> :sys.get_state(port).subscribers == %{} end)

    assert :ok = Port.subscribe(port)
    assert :ok = Port.unsubscribe(port)
    first = Task.async(fn -> Port.identity(port) end)
    second = Task.async(fn -> Port.find(port) end)
    assert {:ok, _result} = Task.await(first)
    assert {:ok, _result} = Task.await(second)
    refute_receive {:iroh_dist, _event}
  end

  test "P[distribution commands are valid] C[send every command] Q[daemon fields match the protocol]" do
    port = start_port("normal")

    assert_request(Port.dist_listen(port, "a@local"), %{
      "command" => "dist_listen",
      "node_name" => "a@local"
    })

    assert_request(Port.dist_connect(port, "a@local", "b@local"), %{
      "command" => "dist_connect",
      "from_node" => "a@local",
      "target_node" => "b@local"
    })

    assert_request(Port.dist_send(port, 42, <<0, 15, 16, 255>>), %{
      "command" => "dist_send",
      "stream_id" => 42,
      "bytes" => "000f10ff"
    })

    assert_request(Port.dist_credit(port, 42, 65_536), %{
      "command" => "dist_credit",
      "stream_id" => 42,
      "bytes" => 65_536
    })

    assert_request(Port.dist_close(port, 42), %{"command" => "dist_close", "stream_id" => 42})
  end

  test "P[daemon errors or malformed replies arrive] C[correlate responses] Q[explicit errors return safely]" do
    error_port = start_port("error")
    malformed_port = start_port("malformed_response")

    assert {:error, "fake_error"} = Port.dist_listen(error_port, "a@local")
    assert {:error, :malformed_response} = Port.dist_close(malformed_port, 7)
    assert Process.alive?(malformed_port)
  end

  test "P[a malformed event frame arrives] C[decode the frame] Q[the client survives without broadcasting]" do
    port = start_port("malformed_event")
    assert :ok = Port.subscribe(port)

    assert {:ok, %{"command" => "identity"}} = Port.identity(port)
    assert Process.alive?(port)
    refute_receive {:iroh_dist, _event}
  end

  test "P[a request remains unanswered] C[wait through its deadline] Q[timeout returns and client survives]" do
    port = start_port("timeout")

    assert {:error, :timeout} = Port.identity(port, 20)
    assert Process.alive?(port)
  end

  test "P[a call is pending] C[the daemon exits] Q[the caller receives the exit failure]" do
    Process.flag(:trap_exit, true)
    {:ok, port} = Port.start_link(options("exit"))

    assert {:error, {:port_exit, 17}} = Port.identity(port)
    assert_receive {:EXIT, ^port, {:port_exit, 17}}
  end

  defp start_port(mode) do
    start_supervised!(%{
      id: make_ref(),
      start: {Port, :start_link, [options(mode)]},
      restart: :temporary
    })
  end

  defp options(mode) do
    [
      executable: @fake,
      data_dir: System.tmp_dir!(),
      fleet_id: String.duplicate("07", 32),
      node_name: mode
    ]
  end

  defp assert_request({:ok, %{"request" => request}}, expected) do
    assert Map.drop(request, ["id"]) == expected
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, attempts) when attempts > 0, do: fun.() || eventually(fun, attempts - 1)
  defp eventually(_fun, 0), do: false
end

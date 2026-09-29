defmodule ElixirRpc.TalkWorkerTest do
  use ExUnit.Case, async: true

  alias ElixirRpc.IrohDiscovery.Port
  alias ElixirRpc.TalkWorker

  @fake Path.expand("support/fake_iroh_discovery_port.script", __DIR__)

  setup_all do
    File.chmod!(@fake, 0o755)
    :ok
  end

  test "P[a worker has capabilities] C[start discovery and wait] Q[all mechanisms start and capabilities republish]" do
    discovery = start_supervised!({Port, port_options()})

    worker =
      start_supervised!(
        {TalkWorker,
         name: nil,
         discovery: discovery,
         capabilities: %{"gpu" => true, "camera" => true},
         bootstrap_endpoint_ids: ["bootstrap-id"],
         publish_interval: 20}
      )

    assert_eventually(fn -> TalkWorker.status(worker).publish_count >= 2 end)

    assert %{
             capabilities: %{"gpu" => true, "camera" => true},
             network: %{
               "request" => %{
                 "bootstrap_endpoint_ids" => ["bootstrap-id"],
                 "dns" => true,
                 "mdns" => true,
                 "dht" => true,
                 "relay" => true
               }
             },
             last_publish: {:ok, %{"command" => "publish"}}
           } = TalkWorker.status(worker)
  end

  defp port_options do
    [
      executable: @fake,
      data_dir: System.tmp_dir!(),
      fleet_id: String.duplicate("07", 32),
      node_name: "normal"
    ]
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition was not met")

  defp assert_eventually(fun, attempts) do
    case fun.() do
      true -> :ok
      false -> Process.sleep(5) && assert_eventually(fun, attempts - 1)
    end
  end
end

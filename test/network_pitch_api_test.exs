defmodule ElixirRpc.NetworkPitchApiTest do
  use ExUnit.Case, async: false

  alias ElixirRpc.IrohDiscovery.Port
  alias ElixirRpc.{Network, TalkWorker}

  @fake Path.expand("support/fake_iroh_discovery_port.script", __DIR__)

  setup do
    previous = Application.get_env(:elixir_rpc, :authorized_nodes)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:elixir_rpc, :authorized_nodes)
        value -> Application.put_env(:elixir_rpc, :authorized_nodes, value)
      end
    end)

    :ok
  end

  test "P[Partisan is configured] C[read runtime topology] Q[bounded HyParView is active]" do
    assert :partisan_hyparview_peer_service_manager ==
             :partisan_config.get(:peer_service_manager)

    assert %{
             active_min_size: 3,
             active_max_size: 6,
             passive_max_size: 30
           } = :partisan_config.get(:hyparview)
  end

  test "P[a publisher is running] C[advertise capabilities] Q[the complete snapshot publishes immediately]" do
    discovery = start_port("normal", "publisher", nil)

    worker =
      start_supervised!(
        {TalkWorker,
         discovery: discovery, capabilities: %{"camera" => true}, publish_interval: 60_000}
      )

    assert {:ok, %{"command" => "publish"}} = Network.advertise(gpu: 128, storage: 512)

    assert %{
             capabilities: %{gpu: 128, storage: 512},
             publish_count: publish_count,
             last_publish: {:ok, %{"command" => "publish"}}
           } = TalkWorker.status(worker)

    assert publish_count >= 1
  end

  test "P[an authorized capable peer exists] C[spawn work] Q[the selected peer runs the function]" do
    partisan_name = :partisan.node() |> Atom.to_string()
    _discovery = start_port("pitch_peer", partisan_name, ElixirRpc.IrohDiscovery)
    Application.put_env(:elixir_rpc, :authorized_nodes, %{partisan_name => node()})
    caller = self()

    assert {:ok, _pid} = Network.spawn([gpu: true], fn -> send(caller, :pitch_task_ran) end)
    assert_receive :pitch_task_ran, 1_000
  end

  test "P[a discovered name is unauthorized] C[spawn work] Q[placement rejects the name]" do
    _discovery = start_port("pitch_peer", "stranger@host", ElixirRpc.IrohDiscovery)
    Application.put_env(:elixir_rpc, :authorized_nodes, %{})

    assert {:error, {:unauthorized_node_name, "stranger@host"}} =
             Network.spawn([gpu: true], fn -> :never end)
  end

  defp start_port(mode, peer_name, name) do
    start_supervised!(%{
      id: make_ref(),
      start:
        {Port, :start_link,
         [
           [
             name: name,
             executable: @fake,
             data_dir: peer_name,
             fleet_id: String.duplicate("07", 32),
             node_name: mode
           ]
         ]},
      restart: :temporary
    })
  end
end

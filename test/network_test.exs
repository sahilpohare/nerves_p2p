defmodule ElixirRpc.NetworkTest do
  use ExUnit.Case, async: false

  alias ElixirRpc.{Network, IrohDiscovery.Port}

  @fake Path.expand("support/fake_iroh_discovery_port.script", __DIR__)

  setup_all do
    File.chmod!(@fake, 0o755)
    :ok
  end

  test "P[an authorized peer matches requirements] C[start a child] Q[Horde hands off to that member]" do
    partisan_name = :partisan.node() |> Atom.to_string()
    discovery = start_port("local_peer", partisan_name)
    id = make_ref()
    child_spec = %{id: id, start: {Agent, :start_link, [fn -> :started end]}}

    requirements = %{
      camera: true,
      site: "north",
      cores: {:at_least, 4},
      formats: {:contains, "raw"}
    }

    assert {:ok, pid} =
             Network.start_child(requirements, child_spec,
               discovery: discovery,
               authorized_nodes: %{partisan_name => node()},
               timeout: 100
             )

    on_exit(fn -> Horde.DynamicSupervisor.terminate_child(ElixirRpc.DynamicSupervisor, pid) end)
    assert Process.alive?(pid)
  end

  test "P[discovery is running] C[list capabilities] Q[find executes without predicates]" do
    discovery = start_port("no_peer", "unused")
    assert {:ok, %{"peers" => []}} = Network.capabilities(discovery)
  end

  test "P[discovery has no peers] C[start a child] Q[no_matching_peer returns]" do
    discovery = start_port("no_peer", "unused")

    assert {:error, :no_matching_peer} =
             Network.start_child(%{}, child_spec(),
               discovery: discovery,
               authorized_nodes: %{}
             )
  end

  test "P[a peer name is not authorized] C[start a child] Q[the name is rejected]" do
    discovery = start_port("unauthorized", "unused")

    assert {:error, {:unauthorized_node_name, "stranger@host"}} =
             Network.start_child(%{}, child_spec(),
               discovery: discovery,
               authorized_nodes: %{}
             )
  end

  test "P[a signed Partisan endpoint is invalid] C[start a child] Q[the endpoint is rejected]" do
    discovery = start_port("invalid_endpoint", "local@host")

    assert {:error, :invalid_partisan_endpoint} =
             Network.start_child(%{}, child_spec(),
               discovery: discovery,
               authorized_nodes: %{"local@host" => node()}
             )
  end

  test "P[a selected peer cannot join Horde] C[start a child] Q[the handoff failure is labeled]" do
    discovery = start_port("handoff", "missing@host")

    assert {:error, {:handoff_failed, :peer_unavailable}} =
             Network.start_child(%{}, child_spec(),
               discovery: discovery,
               authorized_nodes: %{"missing@host" => :missing@host},
               timeout: 10
             )
  end

  defp child_spec do
    %{id: make_ref(), start: {Agent, :start_link, [fn -> nil end]}}
  end

  defp start_port(mode, peer_name) do
    start_supervised!(%{
      id: make_ref(),
      start:
        {Port, :start_link,
         [
           [
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

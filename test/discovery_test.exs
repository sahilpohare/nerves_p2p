defmodule ElixirRpc.DiscoveryTest do
  use ExUnit.Case, async: false

  alias ElixirRpc.Discovery
  alias ElixirRpc.Discovery.{DhtProvider, MdnsProvider}
  alias ElixirRpc.P2P.Node
  alias ElixirRpc.P2P.Node.Event.{DHTQueryResult, PeerDiscovered}
  alias ElixirRpc.P2P.Node.HandlerRegistry
  alias ElixirRpc.PeerId

  @peer_id "12D3KooWRPmBBCBTuGh1cnUuFVr35GYnm4bRXYsSB94TXJLAg4mA"

  test "P[Discovery is supervised] C[terminate its process] Q[it restarts stably]" do
    discovery = Process.whereis(Discovery)
    assert is_pid(discovery)

    Process.exit(discovery, :kill)

    assert eventually(fn ->
             restarted = Process.whereis(Discovery)
             is_pid(restarted) and restarted != discovery and Process.alive?(restarted)
           end)
  end

  test "P[an mDNS peer event arrives] C[ingest the event] Q[the peer becomes discoverable]" do
    %{discovery: discovery, node: node} = start_discovery(MdnsProvider)
    peer_id = PeerId.new!(@peer_id)

    HandlerRegistry.dispatch(
      HandlerRegistry,
      node,
      :peer_discovered,
      %PeerDiscovered{peer_id: peer_id, addresses: ["/ip4/10.0.0.2/tcp/4001"]}
    )

    :ok = HandlerRegistry.sync(HandlerRegistry)

    assert [%{peer_id: @peer_id, listen_addrs: ["/ip4/10.0.0.2/tcp/4001"]}] =
             GenServer.call(discovery, :get_discovered_peers)
  end

  test "P[a DHT result has capabilities] C[scan the provider] Q[the capability cache updates]" do
    %{discovery: discovery, node: node} = start_discovery(DhtProvider)

    assert {:ok, []} = GenServer.call(discovery, {:find_capability, :camera})

    HandlerRegistry.dispatch(
      HandlerRegistry,
      node,
      :dht_query_result,
      %DHTQueryResult{query_id: "1", result: {:found_providers, [@peer_id]}}
    )

    :ok = HandlerRegistry.sync(HandlerRegistry)

    assert {:ok, [%{peer_id: @peer_id, capabilities: [:camera]}]} =
             GenServer.call(discovery, {:find_capability, :camera})
  end

  defp start_discovery(provider) do
    node = start_supervised!({Node, native_module: ElixirRpc.P2P.Native.Mock})

    discovery =
      start_supervised!(
        {Discovery, name: {:global, make_ref()}, providers: [provider], node: node}
      )

    %{discovery: discovery, node: node}
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      true ->
        true

      false ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end

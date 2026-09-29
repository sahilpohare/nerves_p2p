defmodule ElixirRpc.OTP.DistributionTest do
  use ExUnit.Case, async: true

  alias ElixirRpc.OTP.Distribution
  alias ElixirRpc.OTP.Distribution.Server
  alias ElixirRpc.P2P.Node.Event.OutboundResponse
  alias ElixirRpc.PeerId

  @peer PeerId.new!("12D3KooWDpJ7As7BWAwRMfu1VU2WCqNjvq387JEYKDBj4kx6nXTN")

  setup do
    {:ok, node} = GenServer.start_link(__MODULE__.Node, self())
    {:ok, router} = Server.start_link(node: node)
    %{node: node, router: router}
  end

  test "P[two calls are pending] C[respond in reverse order] Q[each caller receives its response]",
       %{node: node, router: router} do
    first = Task.async(fn -> Distribution.call(node, @peer, :target, :first) end)
    assert_receive {:request, :first, first_id}, 1_000

    second = Task.async(fn -> Distribution.call(node, @peer, :target, :second) end)
    assert_receive {:request, :second, second_id}, 1_000

    respond(router, second_id, :second_reply)
    respond(router, first_id, :first_reply)

    assert Task.await(first) == {:ok, :first_reply}
    assert Task.await(second) == {:ok, :second_reply}
  end

  test "P[a prior call timed out] C[deliver stale then current responses] Q[only the current call completes]",
       %{node: node, router: router} do
    timed_out = Task.async(fn -> Distribution.call(node, @peer, :target, :old, 10) end)
    assert_receive {:request, :old, old_id}, 1_000
    assert Task.await(timed_out) == {:error, :timeout}

    next = Task.async(fn -> Distribution.call(node, @peer, :target, :new, 1_000) end)
    assert_receive {:request, :new, new_id}, 1_000

    respond(router, old_id, :stale)
    respond(router, new_id, :fresh)

    assert Task.await(next) == {:ok, :fresh}
  end

  defp respond(router, request_id, reply) do
    send(router, {
      :libp2p,
      :outbound_response,
      %OutboundResponse{
        request_id: request_id,
        peer_id: @peer,
        data: Distribution.encode({:reply, reply})
      }
    })
  end

  defmodule Node do
    use GenServer

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:rpc_send_request, _peer, payload}, _from, owner) do
      {:ok, {:call, _name, message}} = Distribution.decode(payload)
      request_id = "request-#{System.unique_integer([:positive])}"
      send(owner, {:request, message, request_id})
      {:reply, {:ok, request_id}, owner}
    end
  end
end

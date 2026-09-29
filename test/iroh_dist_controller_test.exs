defmodule ElixirRpc.IrohDistControllerTest do
  use ExUnit.Case, async: true

  @moduletag :iroh_dist

  test "P[packet-2 bytes are arbitrarily split] C[feed every split] Q[frames and residue are exact]" do
    wire = :iroh_dist_controller.frame(2, "one") <> :iroh_dist_controller.frame(2, "two")

    for split <- 0..byte_size(wire) do
      <<left::binary-size(split), right::binary>> = wire
      {first, residue} = :iroh_dist_controller.feed(2, <<>>, left)
      {second, residue} = :iroh_dist_controller.feed(2, residue, right)
      assert first ++ second == ["one", "two"]
      assert residue == <<>>
    end

    assert {[], <<0>>} = :iroh_dist_controller.feed(2, <<>>, <<0>>)
  end

  test "P[packet-4 bytes include ticks and frames] C[feed every split] Q[all payloads remain exact]" do
    wire =
      :iroh_dist_controller.frame(4, <<>>) <>
        :iroh_dist_controller.frame(4, "payload") <>
        :iroh_dist_controller.frame(4, "next")

    for split <- 0..byte_size(wire) do
      <<left::binary-size(split), right::binary>> = wire
      {first, residue} = :iroh_dist_controller.feed(4, <<>>, left)
      {second, residue} = :iroh_dist_controller.feed(4, residue, right)
      assert first ++ second == [<<>>, "payload", "next"]
      assert residue == <<>>
    end
  end

  test "P[handshake and data share a chunk] C[receive one handshake packet] Q[packet-4 residue remains]" do
    {:ok, controller} =
      :iroh_dist_controller.start_link(__MODULE__.FakePort, self(), 7, 256 * 1024)

    assert_receive {:subscribe, ^controller}

    handshake = :iroh_dist_controller.frame(2, "challenge")
    residue = :iroh_dist_controller.frame(4, "distribution")

    receiver = Task.async(fn -> :iroh_dist_controller.recv(controller, 0, :infinity) end)
    send(controller, {:iroh_dist, data_event(7, handshake <> residue)})
    assert Task.await(receiver) == {:ok, ~c"challenge"}

    # The packet-4 bytes remain buffered without being mistaken for another
    # handshake packet; only the one requested packet is counted.
    assert {:ok, 1, 0, 0} = :iroh_dist_controller.getstat(controller)

    # A different stream is ignored.
    send(controller, {:iroh_dist, data_event(8, :iroh_dist_controller.frame(2, "wrong"))})
    assert {:ok, 1, 0, 0} = :iroh_dist_controller.getstat(controller)
  end

  test "P[a handshake stream has bounded credit] C[send and close] Q[framing credit and closure propagate]" do
    Process.flag(:trap_exit, true)

    {:ok, controller} = :iroh_dist_controller.start_link(__MODULE__.FakePort, self(), 9, 5)
    assert_receive {:subscribe, ^controller}

    assert :ok = :iroh_dist_controller.send(controller, "abc")
    assert_receive {:dist_send, 9, <<3::16, "abc">>}
    assert {:error, :no_credit} = :iroh_dist_controller.send(controller, "x")

    send(controller, {:iroh_dist, %{"event" => "dist_credit", "stream_id" => 9, "bytes" => 3}})
    assert :ok = :iroh_dist_controller.send(controller, "x")
    assert_receive {:dist_send, 9, <<1::16, "x">>}

    send(controller, {:iroh_dist, %{"event" => "dist_closed", "stream_id" => 10}})
    refute_receive {:EXIT, ^controller, _}
    send(controller, {:iroh_dist, %{"event" => "dist_closed", "stream_id" => 9}})
    assert_receive {:EXIT, ^controller, :connection_closed}
  end

  test "P[receive credit cannot be returned] C[consume stream data] Q[the controller closes instead of stalling]" do
    Process.flag(:trap_exit, true)

    {:ok, controller} =
      :iroh_dist_controller.start_link(__MODULE__.FailingCreditPort, self(), 10, 256 * 1024)

    assert_receive {:subscribe, ^controller}
    send(controller, {:iroh_dist, data_event(10, :iroh_dist_controller.frame(2, "hello"))})

    assert_receive {:dist_close, 10}
    assert_receive {:EXIT, ^controller, {:dist_credit, {:error, :credit_failed}}}
  end

  defp data_event(stream, bytes) do
    %{"event" => "dist_data", "stream_id" => stream, "bytes" => Base.encode16(bytes)}
  end

  defmodule FakePort do
    def subscribe(owner, subscriber) do
      send(owner, {:subscribe, subscriber})
      :ok
    end

    def dist_send(owner, stream, bytes) do
      send(owner, {:dist_send, stream, bytes})
      {:ok, %{}}
    end

    def dist_credit(owner, stream, bytes) do
      send(owner, {:dist_credit, stream, bytes})
      {:ok, %{}}
    end

    def dist_close(owner, stream) do
      send(owner, {:dist_close, stream})
      {:ok, %{}}
    end
  end

  defmodule FailingCreditPort do
    def subscribe(owner, subscriber) do
      send(owner, {:subscribe, subscriber})
      :ok
    end

    def dist_credit(_owner, _stream, _bytes), do: {:error, :credit_failed}

    def dist_close(owner, stream) do
      send(owner, {:dist_close, stream})
      {:ok, %{}}
    end
  end
end

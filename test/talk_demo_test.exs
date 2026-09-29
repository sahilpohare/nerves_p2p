defmodule ElixirRpc.TalkDemoTest do
  use ExUnit.Case, async: false

  alias ElixirRpc.TalkDemo

  @fake Path.expand("support/fake_iroh_discovery_port.script", __DIR__)

  setup_all do
    File.chmod!(@fake, 0o755)
    :ok
  end

  test "P[no remote GPU exists] C[run remote discovery] Q[attempts report and timeout]" do
    Process.put(:events, [])

    assert_raise RuntimeError, ~r/remote Raspberry Pi GPU discovery timed out/, fn ->
      TalkDemo.run(remote_options("remote_timeout", discovery_timeout: 10), &record_event/1)
    end

    events = Process.get(:events)
    assert Enum.any?(events, &(&1.type == "discovery_attempt"))
    assert Enum.any?(events, &(&1.message =~ "remote Raspberry Pi"))
  end

  test "P[a remote GPU record exists] C[run remote discovery] Q[the Pi is selected and handed off]" do
    Process.put(:events, [])

    opts =
      remote_options("remote_success",
        authorized_nodes: %{"remote@rpi4.local" => node()},
        bootstrap_endpoint_ids: ["provisioned-bootstrap"]
      )

    assert :ok = TalkDemo.run(opts, &record_event/1)

    events = Process.get(:events)

    assert Enum.any?(events, fn event ->
             event.type == "peer" and event.message =~ "selected remote Raspberry Pi"
           end)

    assert Enum.any?(events, fn event ->
             event.type == "result" and event.message =~ "remote Raspberry Pi result"
           end)
  end

  defp remote_options(marker, extra) do
    Keyword.merge(
      [
        mode: :remote,
        executable: @fake,
        root: Path.join(System.tmp_dir!(), marker),
        fleet: String.duplicate("07", 32),
        discovery_poll_interval: 1,
        discovery_timeout: 100,
        handoff_timeout: 100
      ],
      extra
    )
  end

  defp record_event(event), do: Process.put(:events, Process.get(:events, []) ++ [event])
end

defmodule Mix.Tasks.Talk.DemoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tag timeout: 15_000
  test "P[two Iroh daemons can start] C[run the talk task] Q[discovery and honest local placement complete]" do
    output = capture_io(fn -> Mix.Tasks.Talk.Demo.run([]) end)

    assert output =~ "STAGE 1: REAL IROH DISCOVERY (two daemon processes)"
    assert output =~ "selected peer:"
    assert output =~ "STAGE 2: LOCAL HORDE PLACEMENT (not remote BEAM placement)"
    assert output =~ "result: {:demo_result, \"talk-worker-"
  end
end

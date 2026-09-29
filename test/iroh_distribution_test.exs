defmodule ElixirRpc.IrohDistributionTest do
  use ExUnit.Case, async: true

  test "P[the VM did not select Iroh distribution] C[start the carrier] Q[an explicit protocol error returns]" do
    assert {:error, :iroh_protocol_not_selected} = ElixirRpc.IrohDistribution.start()
  end
end

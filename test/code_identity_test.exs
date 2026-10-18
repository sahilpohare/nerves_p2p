defmodule ElixirRpc.CodeIdentityTest do
  use ExUnit.Case, async: true

  alias ElixirRpc.{CodeIdentity, DemoWorker}

  test "P[a module is loaded] C[advertise and require it] Q[the requirement matches only the advertised hash]" do
    md5 = Base.encode16(DemoWorker.module_info(:md5), case: :lower)
    entry = "ElixirRpc.DemoWorker:" <> md5

    assert entry in CodeIdentity.advertised()
    assert {:code, {:contains, ^entry}} = CodeIdentity.requirement(DemoWorker)
    refute CodeIdentity.entry(ElixirRpc.Network) in CodeIdentity.advertised()
  end
end

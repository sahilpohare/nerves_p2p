defmodule ElixirRpc.HoareContractTest do
  use ExUnit.Case, async: true

  @exunit_contract ~r/^P\[[^]]+\] C\[[^]]+\] Q\[[^]]+\]$/
  @rust_contract ~r/^p_.+_c_.+_q_.+$/
  @rust_test ~r/#\[(?:tokio::)?test(?:\([^]]*\))?\]\s*(?:async\s+)?fn\s+([a-zA-Z0-9_]+)/m

  test "P[automated test sources exist] C[scan every test declaration] Q[each test states an ordered Hoare triple]" do
    invalid_exunit =
      for path <- Path.wildcard("test/**/*_test.exs"),
          [name] <- Regex.scan(~r/\btest\s+"([^"]+)"/, File.read!(path), capture: :all_but_first),
          not Regex.match?(@exunit_contract, name),
          do: {path, name}

    rust_paths =
      Path.wildcard("native/iroh_discovery/src/**/*.rs") ++
        Path.wildcard("native/iroh_discovery/tests/**/*.rs")

    invalid_rust =
      for path <- rust_paths,
          [name] <- Regex.scan(@rust_test, File.read!(path), capture: :all_but_first),
          not Regex.match?(@rust_contract, name),
          do: {path, name}

    assert invalid_exunit == []
    assert invalid_rust == []
  end
end

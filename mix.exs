defmodule ElixirRpc.MixProject do
  use Mix.Project

  @app :elixir_rpc
  @version "0.1.0"
  @source_url "https://github.com/sahilpohare/nerves_p2p"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:iroh_discovery | Mix.compilers()],
      description: "Capability-based process placement over Iroh, Partisan and Horde.",
      package: package(),
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md", "ARCHITECTURE.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :partisan],
      mod: {ElixirRpc.Application, []}
    ]
  end

  # Demo (dashboard, TUI, mix tasks) compiles only in dev/test.
  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_), do: ["lib", "examples/talk/lib"]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib native/iroh_discovery/src native/iroh_discovery/Cargo.* native/p2p_bridge/src
                native/p2p_bridge/Cargo.* src mix.exs README.md ARCHITECTURE.md)
    ]
  end

  defp deps do
    [
      {:libp2p_elixir, "~> 0.9.6"},
      {:partisan, "~> 5.0"},
      {:ex_hash_ring, "~> 6.0"},
      {:delta_crdt, "~> 0.6"},
      {:horde, github: "elixir-horde/horde", branch: "master"},
      {:telemetry, "~> 1.1"},
      {:rustler, "~> 0.36", runtime: false},

      # Demo only
      {:owl, "~> 0.13", only: [:dev, :test]},
      {:plug, "~> 1.16", only: [:dev, :test]},
      {:bandit, "~> 1.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end

defmodule Mix.Tasks.Compile.IrohDiscovery do
  @shortdoc "Builds the iroh_discovery_port daemon into priv/bin"
  @moduledoc """
  Runs `cargo build` for `native/iroh_discovery` and copies the daemon to
  `priv/bin/iroh_discovery_port` (release in prod, debug otherwise).
  Set `CARGO_BUILD_TARGET` to cross-compile; `ELIXIR_RPC_SKIP_IROH_BUILD=1` skips.
  """
  use Mix.Task.Compiler

  @bin "iroh_discovery_port"

  @impl true
  def run(_args) do
    if System.get_env("ELIXIR_RPC_SKIP_IROH_BUILD") in [nil, ""], do: build()
    {:ok, []}
  end

  defp build do
    profile = if Mix.env() == :prod, do: "release", else: "debug"
    dir = Path.join(File.cwd!(), "native/iroh_discovery")
    args = ["build", "--bin", @bin] ++ if(profile == "release", do: ["--release"], else: [])

    case System.cmd("cargo", args, cd: dir, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, code} -> Mix.raise("cargo build of #{@bin} failed (exit #{code})")
    end

    triple = System.get_env("CARGO_BUILD_TARGET")
    built = Path.join([dir, "target", triple || "", profile, @bin])
    dest = Path.join([Mix.Project.app_path(), "priv", "bin", @bin])
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(built, dest)
  end
end

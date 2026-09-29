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
      # ponytail: local fork with uncommitted Partisan changes; publish the fork (git dep) before releasing.
      {:horde, path: "../horde"},
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

defmodule Mix.Tasks.Talk.Ui do
  use Mix.Task

  @shortdoc "Launch the browser dashboard for the talk demo"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    port = parse_port(args)
    demo_opts = demo_options()
    {:ok, _} = Application.ensure_all_started(:bandit)

    {:ok, _pid} =
      ElixirRpc.TalkWeb.start_link(port: port, demo: &ElixirRpc.TalkDemo.run(demo_opts, &1))

    Mix.shell().info("Talk dashboard: http://127.0.0.1:#{port}")
    Process.sleep(:infinity)
  end

  defp demo_options do
    mode =
      case System.get_env("TALK_DEMO_MODE", "local") do
        "local" -> :local
        "remote" -> :remote
        value -> Mix.raise("TALK_DEMO_MODE must be local or remote, got: #{value}")
      end

    bootstrap_endpoint_ids =
      System.get_env("TALK_BOOTSTRAP_ENDPOINT_IDS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    options = [mode: mode, bootstrap_endpoint_ids: bootstrap_endpoint_ids]

    case mode do
      :remote -> Keyword.put(options, :fleet, System.fetch_env!("IROH_FLEET_ID"))
      :local -> options
    end
  end

  defp parse_port([port]) do
    case Integer.parse(port) do
      {value, ""} when value in 1..65_535 -> value
      _ -> Mix.raise("usage: mix talk.ui [port]")
    end
  end

  defp parse_port([]), do: 4000
  defp parse_port(_args), do: Mix.raise("usage: mix talk.ui [port]")
end

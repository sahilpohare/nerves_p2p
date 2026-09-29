defmodule Mix.Tasks.Talk.Demo do
  use Mix.Task

  @shortdoc "Run the real Iroh discovery and local Horde talk demo"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args), do: ElixirRpc.TalkDemo.run([], &IO.puts(&1.message))
end

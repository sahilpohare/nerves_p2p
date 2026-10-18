defmodule Mix.Tasks.Tui do
  @shortdoc "Launch the ElixirRpc P2P mesh TUI"

  @moduledoc """
  Starts the application and opens the terminal UI.

      mix tui

  The TUI shows live peer connections, mesh topology, an RPC call prompt,
  and a streaming event log.

  Keyboard:
  - Tab / Shift-Tab — switch panels
  - q               — quit
  - Enter (RPC)     — open call prompt
  - Esc  (RPC)      — cancel editing

  RPC call format:
      <peer_id_prefix> <server_name> <Module> <function> [json_args]

  Example (call String.upcase on a remote CapabilityRPC.Server):
      12D3KooW __capability_rpc_server__ String upcase ["hello"]
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    # Put terminal in raw mode so we can read keystrokes without Enter
    set_raw_mode(true)

    try do
      ElixirRpc.TUI.run()
    after
      set_raw_mode(false)
      # restore cursor
      IO.write("\e[?25h")
    end
  end

  defp set_raw_mode(true) do
    # Hide cursor, disable echo and canonical mode via stty
    IO.write("\e[?25l")
    System.cmd("stty", ["-echo", "-icanon", "min", "1", "time", "0"], stderr_to_stdout: true)
  end

  defp set_raw_mode(false) do
    System.cmd("stty", ["echo", "icanon"], stderr_to_stdout: true)
  end
end

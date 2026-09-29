defmodule ElixirRpc.TUI do
  @moduledoc """
  Terminal UI for the ElixirRpc P2P mesh.

  Panels:
  - PEERS   — live connected peer list with IDs and addresses
  - TOPOLOGY — ASCII adjacency graph of who is connected to whom
  - RPC     — interactive prompt to call a remote process
  - LOGS    — tail of libp2p events (connection, discovery, requests)

  Navigation: Tab / Shift-Tab to switch panels, q to quit.
  In RPC panel: press Enter to open the call prompt.
  """

  use GenServer
  require Logger

  alias ElixirRpc.P2P.Node
  alias ElixirRpc.{PeerId, OTP.Distribution, RequestResponse}

  @refresh_ms 1_000
  @max_logs 200

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run do
    {:ok, pid} = start_link([])
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  # ── State ──────────────────────────────────────────────────────────────────

  defstruct [
    :node,
    :local_peer_id,
    :listen_addrs,
    # [{peer_id_str, [addr]}]
    peers: [],
    # [{timestamp, event_tag, summary}]
    logs: [],
    active_panel: :peers,
    rpc_input: "",
    rpc_history: [],
    rpc_result: nil,
    # :idle | :editing
    rpc_mode: :idle,
    width: 120,
    height: 40
  ]

  # ── Init ───────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    node = ElixirRpc.Node

    # Subscribe to all relevant libp2p events
    Node.register_handler(node, :connection_established, self())
    Node.register_handler(node, :connection_closed, self())
    Node.register_handler(node, :peer_discovered, self())
    Node.register_handler(node, :inbound_request, self())
    Node.register_handler(node, :dht_query_result, self())

    # Also subscribe outbound_response so Distribution.call works from TUI
    RequestResponse.register_handler(node, self())

    {local_str, addrs} = fetch_local_info(node)

    state = %__MODULE__{
      node: node,
      local_peer_id: local_str,
      listen_addrs: addrs,
      logs: []
    }

    # Enter raw mode for keyboard input
    Owl.IO.puts("")
    schedule_refresh()
    schedule_input_poll()

    {:ok, state, {:continue, :initial_render}}
  end

  @impl true
  def handle_continue(:initial_render, state) do
    state = refresh_peers(state)
    render(state)
    {:noreply, state}
  end

  # ── Periodic refresh ───────────────────────────────────────────────────────

  @impl true
  def handle_info(:refresh, state) do
    state = refresh_peers(state)
    render(state)
    schedule_refresh()
    {:noreply, state}
  end

  # ── Keyboard polling ───────────────────────────────────────────────────────

  @impl true
  def handle_info(:poll_input, state) do
    state =
      case read_key() do
        nil ->
          state

        key ->
          state
          |> handle_key(key)
          |> tap(&render/1)
      end

    schedule_input_poll()
    {:noreply, state}
  end

  # ── libp2p events ──────────────────────────────────────────────────────────

  @impl true
  def handle_info({:libp2p, :connection_established, ev}, state) do
    peer_str = PeerId.to_string(ev.peer_id)
    state = push_log(state, :connected, "+ #{short(peer_str)} (#{ev.endpoint})")
    state = refresh_peers(state)
    render(state)
    {:noreply, state}
  end

  def handle_info({:libp2p, :connection_closed, ev}, state) do
    peer_str = PeerId.to_string(ev.peer_id)
    state = push_log(state, :disconnected, "- #{short(peer_str)}")
    state = refresh_peers(state)
    render(state)
    {:noreply, state}
  end

  def handle_info({:libp2p, :peer_discovered, ev}, state) do
    peer_str = PeerId.to_string(ev.peer_id)
    addrs = Enum.join(ev.addresses, ", ")
    state = push_log(state, :discovered, "? #{short(peer_str)}  #{addrs}")
    render(state)
    {:noreply, state}
  end

  def handle_info({:libp2p, :inbound_request, ev}, state) do
    peer_str = PeerId.to_string(ev.peer_id)
    state = push_log(state, :request, "← #{short(peer_str)} req #{short(ev.request_id)}")
    render(state)
    {:noreply, state}
  end

  def handle_info({:libp2p, :dht_query_result, ev}, state) do
    state = push_log(state, :dht, "DHT query #{short(ev.query_id)}")
    render(state)
    {:noreply, state}
  end

  def handle_info({:libp2p, :outbound_response, _ev}, state) do
    # Handled inline by Distribution.call; ignore here
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Key handling ───────────────────────────────────────────────────────────

  defp handle_key(state, "q") when state.rpc_mode == :idle do
    clear_screen()
    Owl.IO.puts(Owl.Data.tag("Bye!", :green))
    Process.exit(self(), :normal)
    state
  end

  defp handle_key(state, "\t") when state.rpc_mode == :idle do
    panels = [:peers, :topology, :rpc, :logs]
    idx = Enum.find_index(panels, &(&1 == state.active_panel))
    next = Enum.at(panels, rem(idx + 1, length(panels)))
    %{state | active_panel: next}
  end

  defp handle_key(state, "\e[Z") when state.rpc_mode == :idle do
    # Shift-Tab
    panels = [:peers, :topology, :rpc, :logs]
    idx = Enum.find_index(panels, &(&1 == state.active_panel))
    prev = Enum.at(panels, rem(idx - 1 + length(panels), length(panels)))
    %{state | active_panel: prev}
  end

  # RPC panel: Enter starts editing
  defp handle_key(%{active_panel: :rpc, rpc_mode: :idle} = state, "\r") do
    %{state | rpc_mode: :editing, rpc_input: "", rpc_result: nil}
  end

  # RPC editing: Enter submits
  defp handle_key(%{rpc_mode: :editing} = state, "\r") do
    result = execute_rpc(state.node, state.rpc_input)
    history = [state.rpc_input | Enum.take(state.rpc_history, 19)]

    %{state | rpc_mode: :idle, rpc_result: result, rpc_history: history, rpc_input: ""}
  end

  # RPC editing: Escape cancels
  defp handle_key(%{rpc_mode: :editing} = state, "\e") do
    %{state | rpc_mode: :idle, rpc_input: ""}
  end

  # RPC editing: Backspace
  defp handle_key(%{rpc_mode: :editing} = state, "\x7f") do
    new_input = String.slice(state.rpc_input, 0..-2//1)
    %{state | rpc_input: new_input}
  end

  # RPC editing: printable chars
  defp handle_key(%{rpc_mode: :editing} = state, char) when byte_size(char) == 1 do
    if String.printable?(char) do
      %{state | rpc_input: state.rpc_input <> char}
    else
      state
    end
  end

  defp handle_key(state, _key), do: state

  # ── RPC execution ──────────────────────────────────────────────────────────
  # Input format:  <peer_id_prefix> <registered_name> <module> <function> [args_json]
  # Example:       12D3KooWAbc my_server String upcase ["hello"]

  defp execute_rpc(node, input) do
    case String.split(String.trim(input), " ", parts: 5) do
      [peer_prefix, reg_name, mod_str, fun_str | rest] ->
        with {:ok, peer_id} <- resolve_peer(node, peer_prefix),
             {:ok, mod} <- safe_module(mod_str),
             fun = String.to_existing_atom(fun_str),
             args = parse_args(List.first(rest, "[]")) do
          RequestResponse.register_handler(node, self())

          Distribution.call(
            node,
            peer_id,
            String.to_existing_atom(reg_name),
            {:apply, mod, fun, args},
            8_000
          )
          |> case do
            {:ok, {:ok, val}} -> {:ok, inspect(val)}
            {:ok, {:error, r}} -> {:error, inspect(r)}
            {:error, r} -> {:error, inspect(r)}
          end
        else
          err -> {:error, inspect(err)}
        end

      _ ->
        {:error, "usage: <peer_prefix> <server_name> <Module> <function> [args_json]"}
    end
  end

  defp resolve_peer(node, prefix) do
    case Node.connected_peers(node) do
      {:ok, peers} ->
        match = Enum.find(peers, &String.starts_with?(PeerId.to_string(&1), prefix))

        if match, do: {:ok, match}, else: {:error, :peer_not_found}

      _ ->
        {:error, :no_peers}
    end
  end

  defp safe_module(str) do
    mod = Module.concat([str])
    if Code.ensure_loaded?(mod), do: {:ok, mod}, else: {:error, {:unknown_module, str}}
  end

  defp parse_args(json_str) do
    case Jason.decode(json_str) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  # ── Data helpers ───────────────────────────────────────────────────────────

  defp refresh_peers(state) do
    peers =
      case Node.connected_peers(state.node) do
        {:ok, peer_ids} -> Enum.map(peer_ids, &PeerId.to_string/1)
        _ -> []
      end

    %{state | peers: peers}
  end

  defp fetch_local_info(node) do
    id =
      case Node.peer_id(node) do
        {:ok, pid} -> PeerId.to_string(pid)
        _ -> "unknown"
      end

    addrs =
      case Node.listening_addrs(node) do
        {:ok, a} -> a
        _ -> []
      end

    {id, addrs}
  end

  defp push_log(state, tag, msg) do
    entry = {time_str(), tag, msg}
    logs = [entry | state.logs] |> Enum.take(@max_logs)
    %{state | logs: logs}
  end

  defp time_str do
    Time.utc_now() |> Time.to_string() |> String.slice(0, 8)
  end

  defp short(str) when byte_size(str) > 16, do: String.slice(str, 0, 8) <> "…"
  defp short(str), do: str

  # ── Rendering ──────────────────────────────────────────────────────────────

  defp render(state) do
    {w, h} = terminal_size()
    state = %{state | width: w, height: h}

    clear_screen()

    render_header(state)
    render_panel(state)
    render_footer(state)
  end

  defp render_header(state) do
    panels = [:peers, :topology, :rpc, :logs]
    labels = %{peers: "PEERS", topology: "TOPOLOGY", rpc: "RPC", logs: "LOGS"}

    tabs =
      Enum.map(panels, fn p ->
        label = " #{labels[p]} "

        if p == state.active_panel do
          Owl.Data.tag(label, [:inverse, :bright])
        else
          Owl.Data.tag(label, :faint)
        end
      end)
      |> Enum.intersperse(Owl.Data.tag("│", :faint))

    local_short = short(state.local_peer_id || "?")

    Owl.IO.puts(
      Owl.Box.new(
        ["P2P Mesh  ", tabs, "   me:", Owl.Data.tag(local_short, :cyan)],
        border_style: :solid_rounded,
        padding: 0,
        min_width: state.width - 2
      )
    )
  end

  defp render_panel(%{active_panel: :peers} = state) do
    content =
      if state.peers == [] do
        [Owl.Data.tag("  No connected peers yet.\n", :yellow)]
      else
        state.peers
        |> Enum.map(fn peer_str ->
          [
            "  ",
            Owl.Data.tag("● ", :green),
            Owl.Data.tag(peer_str, :bright),
            "\n"
          ]
        end)
      end

    title = "Connected Peers (#{length(state.peers)})"
    print_panel(title, content, state)
  end

  defp render_panel(%{active_panel: :topology} = state) do
    local = state.local_peer_id || "?"
    local_s = short(local)

    lines =
      if state.peers == [] do
        [Owl.Data.tag("  (no peers connected)\n", :faint)]
      else
        peer_lines =
          Enum.map(state.peers, fn p ->
            ["  ", Owl.Data.tag(local_s, :cyan), " ── ", Owl.Data.tag(short(p), :green), "\n"]
          end)

        [
          ["  ", Owl.Data.tag(local_s, [:cyan, :bright]), " (this node)\n"]
          | peer_lines
        ]
      end

    print_panel("Mesh Topology", lines, state)
  end

  defp render_panel(%{active_panel: :rpc} = state) do
    peers_hint =
      if state.peers == [] do
        Owl.Data.tag("  No peers connected.\n", :yellow)
      else
        state.peers
        |> Enum.take(5)
        |> Enum.map(fn p ->
          ["  ", Owl.Data.tag(short(p), :cyan), "\n"]
        end)
      end

    prompt_line =
      case state.rpc_mode do
        :editing ->
          [
            Owl.Data.tag("  > ", [:green, :bright]),
            Owl.Data.tag(state.rpc_input, :bright),
            Owl.Data.tag("█", :blink),
            "\n"
          ]

        :idle ->
          [Owl.Data.tag("  Press Enter to type a call…\n", :faint)]
      end

    result_line =
      case state.rpc_result do
        nil -> []
        {:ok, val} -> [Owl.Data.tag("  ✓ #{val}\n", :green)]
        {:error, err} -> [Owl.Data.tag("  ✗ #{err}\n", :red)]
      end

    hint = [
      Owl.Data.tag("  Format: ", :faint),
      Owl.Data.tag("<peer_prefix> <server> <Module> <fun> [json_args]\n", :faint)
    ]

    history_lines =
      state.rpc_history
      |> Enum.take(5)
      |> Enum.map(fn h -> [Owl.Data.tag("  #{h}\n", :faint)] end)

    content = [
      Owl.Data.tag("  Connected peers:\n", :faint),
      peers_hint,
      "\n",
      hint,
      prompt_line,
      result_line,
      if(history_lines != [],
        do: [Owl.Data.tag("  History:\n", :faint) | history_lines],
        else: []
      )
    ]

    print_panel("RPC Call", content, state)
  end

  defp render_panel(%{active_panel: :logs} = state) do
    tag_color = %{
      connected: :green,
      disconnected: :red,
      discovered: :yellow,
      request: :cyan,
      dht: :magenta
    }

    lines =
      if state.logs == [] do
        [Owl.Data.tag("  Waiting for events…\n", :faint)]
      else
        state.logs
        |> Enum.take(state.height - 8)
        |> Enum.map(fn {ts, tag, msg} ->
          color = Map.get(tag_color, tag, :white)

          [
            Owl.Data.tag("  #{ts} ", :faint),
            Owl.Data.tag("[#{tag}]", color),
            " #{msg}\n"
          ]
        end)
      end

    print_panel("Event Log (#{length(state.logs)})", lines, state)
  end

  defp print_panel(title, content, state) do
    Owl.IO.puts(
      Owl.Box.new(
        content,
        title: Owl.Data.tag(" #{title} ", :bright),
        border_style: :solid_rounded,
        padding_x: 0,
        min_width: state.width - 2,
        min_height: state.height - 8
      )
    )
  end

  defp render_footer(state) do
    keys =
      if state.rpc_mode == :editing do
        "  Enter=submit   Esc=cancel   Backspace=delete"
      else
        "  Tab=next panel   q=quit   (RPC panel: Enter=call)"
      end

    Owl.IO.puts(Owl.Data.tag(keys, :faint))

    Owl.IO.puts(
      Owl.Data.tag(
        "  Listen: #{Enum.join(state.listen_addrs, ", ")}",
        :faint
      )
    )
  end

  # ── Terminal helpers ────────────────────────────────────────────────────────

  defp clear_screen do
    IO.write("\e[2J\e[H")
  end

  defp terminal_size do
    case :io.columns() do
      {:ok, cols} ->
        rows =
          case :io.rows() do
            {:ok, r} -> r
            _ -> 40
          end

        {cols, rows}

      _ ->
        {120, 40}
    end
  end

  # Non-blocking single-char read using :io in raw mode
  defp read_key do
    case IO.getn("", 1) do
      :eof ->
        nil

      "" ->
        nil

      ch ->
        # Slurp escape sequences (arrows etc.)
        if ch == "\e" do
          rest = slurp_escape()
          "\e" <> rest
        else
          ch
        end
    end
  end

  defp slurp_escape do
    try do
      case :io.get_chars(~c"", 2) do
        seq when is_list(seq) -> List.to_string(seq)
        seq when is_binary(seq) -> seq
        _ -> ""
      end
    catch
      _, _ -> ""
    end
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)
  defp schedule_input_poll, do: Process.send_after(self(), :poll_input, 50)
end

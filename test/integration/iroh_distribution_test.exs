defmodule ElixirRpc.Integration.IrohDistributionTest do
  use ExUnit.Case, async: false

  @moduletag :iroh_dist_integration
  @moduletag skip: System.get_env("IROH_DIST_INTEGRATION") != "1"

  test "P[two BEAM nodes start over Iroh] C[exercise bounded OTP traffic] Q[ping RPC large payload PID and monitor semantics hold]" do
    daemon = System.fetch_env!("IROH_DISCOVERY_BIN")
    assert File.exists?(daemon), "IROH_DISCOVERY_BIN does not exist: #{daemon}"

    root = Path.join(System.tmp_dir!(), "iroh-dist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    script = Path.expand("../../scripts/iroh_dist_node.exs", __DIR__)
    fleet = String.duplicate("07", 32)
    a = start_node(script, daemon, root, fleet, "a")
    b = start_node(script, daemon, root, fleet, "b")

    on_exit(fn -> Enum.each([a, b], fn {_role, port} -> safe_close(port) end) end)

    result =
      case await_term(Path.join(root, "result"), 30_000) do
        {:ok, result} -> result
        error -> flunk("Iroh node harness failed: #{inspect(error)}\n#{node_output([a, b])}")
      end

    assert result.ping == :pong, node_output([a, b])
    assert result.rpc == 42
    assert result.large_rpc == 128 * 1024
    assert result.remote_pid_node == :"a@127.0.0.1"
    assert result.monitor == :killed
  end

  defp start_node(script, daemon, root, fleet, role) do
    executable = System.find_executable("elixir") || flunk("elixir executable not found")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "--erl",
          "-proto_dist iroh -no_epmd",
          "-S",
          "mix",
          "run",
          "--no-start",
          "--no-compile",
          script,
          role,
          root,
          daemon,
          fleet
        ]
      ])

    {role, port}
  end

  defp await_term(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_term(path, deadline)
  end

  defp do_await_term(path, deadline) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, :erlang.binary_to_term(bytes)}

      error ->
        await_retry(path, deadline, error, System.monotonic_time(:millisecond) < deadline)
    end
  end

  defp await_retry(path, deadline, _error, true) do
    Process.sleep(50)
    do_await_term(path, deadline)
  end

  defp await_retry(_path, _deadline, error, false), do: error

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp node_output(nodes),
    do: receive_output(Map.new(nodes, fn {role, port} -> {port, role} end), [])

  defp receive_output(nodes, output) do
    receive do
      {port, {:data, data}} ->
        receive_output(nodes, ["[#{nodes[port]}] ", data | output])

      {port, {:exit_status, status}} ->
        receive_output(nodes, ["[#{nodes[port]}] exit #{status}\n" | output])
    after
      100 -> output |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end

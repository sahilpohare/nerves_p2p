alias ElixirRpc.Network

# Keep this trusted mapping in application configuration. Never create atoms from
# node names received through discovery.
Application.put_env(:elixir_rpc, :authorized_nodes, %{
  "gpu@nerves.local" => :"gpu@nerves.local"
})

{:ok, pid} =
  Network.spawn([gpu: true, vram_mb: {:at_least, 4_096}], fn ->
    IO.puts("running on #{inspect(node())}")
  end)

IO.inspect(pid, label: "started worker")

#!/usr/bin/env elixir

# Start the application
{:ok, _} = Application.ensure_all_started(:elixir_rpc)

# Give it a moment to start
Process.sleep(2000)

# Test the libp2p bridge
IO.puts("\n=== Testing libp2p Bridge ===")

case ElixirRpc.Libp2pBridge.get_peer_id() do
  nil ->
    IO.puts("⏳ Peer ID not yet available...")
    Process.sleep(1000)

    case ElixirRpc.Libp2pBridge.get_peer_id() do
      nil -> IO.puts("❌ Failed to get peer ID")
      peer_id -> IO.puts("✅ Peer ID: #{peer_id}")
    end

  peer_id ->
    IO.puts("✅ Peer ID: #{peer_id}")
end

case ElixirRpc.Libp2pBridge.get_listen_addrs() do
  addrs when is_list(addrs) and length(addrs) > 0 ->
    IO.puts("✅ Listening on #{length(addrs)} addresses:")
    Enum.each(addrs, fn addr -> IO.puts("   - #{addr}") end)

  _ ->
    IO.puts("⏳ No listen addresses yet")
end

IO.puts("\n=== libp2p Bridge Test Complete ===\n")

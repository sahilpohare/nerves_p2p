alias ElixirRpc.Network

{:ok, %{"peers" => peers}} = Network.capabilities()

Enum.each(peers, fn peer ->
  IO.inspect(
    Map.take(peer, ["node_name", "endpoint_id", "capabilities", "load"]),
    label: "capable peer"
  )
end)

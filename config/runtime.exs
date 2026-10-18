import Config

get_available_port = fn ->
  {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
  {:ok, port} = :inet.port(socket)
  :gen_tcp.close(socket)
  port
end

# Generate a unique node name using crypto — available at runtime.exs time
# unlike NIFs. The actual libp2p PeerID format is used by the NIF at app start,
# but for Partisan's internal use any unique stable name works.
generate_node_name = fn host ->
  id = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  :"#{id}@#{host}"
end

if config_env() == :dev or config_env() == :test do
  available_port = get_available_port.()
  node_name = generate_node_name.("127.0.0.1")

  config :partisan,
    name: node_name,
    listen_addrs: [%{ip: {127, 0, 0, 1}, port: available_port}]

  IO.puts("Partisan runtime config: node=#{node_name} port=#{available_port}")
end

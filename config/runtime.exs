import Config

# Runtime configuration that executes when the application starts
# This allows us to dynamically assign ports before Partisan starts

if config_env() == :dev or config_env() == :test do
  # Get an available port from the OS
  get_available_port = fn ->
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  available_port = get_available_port.()

  # Configure Partisan with the OS-assigned port
  config :partisan,
    listen_addrs: [%{ip: {127, 0, 0, 1}, port: available_port}]

  IO.puts("Partisan runtime config: Using OS-assigned port #{available_port}")
end

# For Nerves targets (production)
if config_env() == :prod and Application.get_env(:nerves, :target) != :host do
  # Get an available port from the OS
  get_available_port = fn ->
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  available_port = get_available_port.()

  # Configure Partisan with the OS-assigned port
  config :partisan,
    listen_addrs: [%{ip: {0, 0, 0, 0}, port: available_port}]

  IO.puts("Partisan runtime config: Using OS-assigned port #{available_port}")
end

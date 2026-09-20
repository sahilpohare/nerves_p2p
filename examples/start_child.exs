defmodule Example.GpuWorker do
  use Agent

  def start_link(job_id) do
    Agent.start_link(fn -> %{job_id: job_id, node: node()} end)
  end
end

alias ElixirRpc.Network

job_id = System.unique_integer([:positive, :monotonic])

child_spec = %{
  id: {Example.GpuWorker, job_id},
  restart: :temporary,
  start: {Example.GpuWorker, :start_link, [job_id]}
}

# Keep this trusted mapping in application configuration. Never create atoms from
# node names received through discovery.
authorized_nodes = %{
  "gpu@nerves.local" => :"gpu@nerves.local"
}

{:ok, pid} =
  Network.start_child(
    %{gpu: true, vram_mb: {:at_least, 4_096}},
    child_spec,
    discovery: ElixirRpc.IrohDiscovery,
    authorized_nodes: authorized_nodes,
    timeout: 10_000
  )

IO.inspect(pid, label: "started worker")

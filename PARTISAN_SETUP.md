# Partisan P2P Mesh Networking Setup

This document describes the Partisan integration for peer-to-peer mesh networking in the ElixirRpc project.

## Overview

Partisan has been successfully integrated to provide:
- **P2P Mesh Networking**: HyParView-based partial mesh topology
- **NAT Traversal**: Built-in support for devices behind firewalls
- **Scalable Membership**: Gossip-based peer discovery and failure detection
- **Efficient Routing**: Multi-channel communication for different message types
- **Integration with Nerves**: Leverages existing mDNS discovery via `mdns_lite`

## Architecture

### Components

1. **Partisan Application** (`lib/elixir_rpc/application.ex:20-35`)
   - Starts before the main application
   - Configures node name at runtime based on hostname/IP
   - Listed in `extra_applications` in mix.exs

2. **PartisanConfig Module** (`lib/elixir_rpc/partisan_config.ex`)
   - High-level API for Partisan operations
   - Functions: `join_peer/1`, `members/0`, `send_message/2`, `broadcast/2`
   - Connection management and statistics

3. **PeerManager** (`lib/elixir_rpc/peer_manager.ex`)
   - Integrates with Nerves' VintageNet for network events
   - Manual peer connection via `connect_peer/2`
   - Future: Auto-discovery via mDNS

### Configuration

#### Host Mode (`config/host.exs`)
```elixir
config :partisan,
  peer_service_manager: :partisan_pluggable_peer_service_manager,
  partisan_peer_service_manager: :partisan_hyparview_peer_service_manager,
  channels: [:membership, :rpc, :discovery],
  broadcast: true,
  connection_jitter: 1000,
  tls: false,
  name: :"dev@127.0.0.1",
  listen_addrs: [%{ip: {127, 0, 0, 1}, port: 10200}]
```

#### Target Mode (`config/target.exs`)
```elixir
config :partisan,
  peer_service_manager: :partisan_pluggable_peer_service_manager,
  partisan_peer_service_manager: :partisan_hyparview_peer_service_manager,
  channels: [:membership, :rpc, :discovery, :capabilities],
  broadcast: true,
  periodic_interval: 10_000,
  connection_jitter: 5000,
  min_active_size: 3,
  max_active_size: 6,
  tls: false,
  listen_addrs: [%{ip: {0, 0, 0, 0}, port: 10200}],
  parallelism: 4
```

The Partisan service is advertised via mDNS on port 10200.

## Usage

### Starting the Application

```bash
# Development
iex -S mix

# You should see logs like:
# [info] Partisan configured with node name: :"elixir_rpc@127.0.0.1"
# [info] Starting Peer Manager
```

### Connecting to Peers

```elixir
# In IEx
alias ElixirRpc.{PartisanConfig, PeerManager}

# Connect to a peer by IP
PeerManager.connect_peer("192.168.1.100")

# Check current members
PartisanConfig.members()
# => [%{name: :"elixir_rpc@127.0.0.1", ...}, ...]

# Get connection stats
PartisanConfig.connection_stats()
# => %{node: :"elixir_rpc@127.0.0.1", members: 2, connections: 1}
```

### Sending Messages

```elixir
# Send to specific peer
PartisanConfig.send_message(:"elixir_rpc@192.168.1.100", {:hello, "world"})

# Broadcast to all members
PartisanConfig.broadcast({:announcement, "New capability available"})
```

## Network Topology

Partisan uses the **HyParView** peer service manager which implements:

- **Partial Mesh**: Not all nodes connect to all other nodes
- **Active View**: 3-6 direct connections per node (configurable)
- **Passive View**: Additional known nodes for failover
- **Gossip Protocol**: Membership propagation and failure detection
- **Self-Healing**: Automatic reconnection on partition recovery

### Benefits over Full Mesh

1. **Scalability**: O(log N) connections instead of O(N²)
2. **Resilience**: Multiple redundant paths without full connectivity
3. **Lower Resource Usage**: Fewer TCP connections per node
4. **NAT Friendly**: Works with Partisan's connection strategies

## Integration with Nerves

### mDNS Service Advertisement

The Partisan service is advertised via `mdns_lite` in `config/target.exs`:

```elixir
services: [
  # ... existing services ...
  %{
    protocol: "partisan",
    transport: "tcp",
    port: 10200
  }
]
```

### Network Event Handling

`PeerManager` subscribes to VintageNet events to detect:
- Network interfaces coming up/down
- IP address changes
- Connection state transitions

This enables automatic mesh recovery when network conditions change.

## Automatic Discovery

**Automatic peer discovery is now fully implemented!** Nodes will discover and connect to each other automatically via mDNS.

### How It Works

1. **MdnsAdvertiser** (`lib/elixir_rpc/mdns_advertiser.ex`) - Advertises this node's Partisan service
   - Only runs on Nerves targets (not host mode)
   - Advertises on port 10200 with node metadata

2. **PeerManager** (`lib/elixir_rpc/peer_manager.ex`) - Discovers and connects to peers
   - Scans every 15 seconds using `NervesDiscovery`
   - Automatically joins newly discovered peers
   - Tracks discovered vs connected peers
   - Triggers discovery when network comes up (VintageNet integration)

### TODO: Capability Advertisement

Extend the mesh to advertise node capabilities:

```elixir
# Register capabilities
PeerDiscovery.register_capability(:camera, %{
  version: "1.0",
  resolution: "1080p",
  fps: 30
})

# Query capabilities across mesh
find_nodes_with_capability(:camera)
```

### TODO: RPC Proxy Layer

Intercept standard Erlang `:rpc` calls and route via Partisan:

```elixir
# Standard call (will be routed via Partisan mesh)
:rpc.call(:"elixir_rpc@peer", MyModule, :function, [args])
```

## Testing

### Multi-Node Testing

To test mesh behavior, start multiple IEx sessions:

```bash
# Terminal 1
MIX_ENV=dev iex --sname node1 -S mix

# Terminal 2
MIX_ENV=dev iex --sname node2 -S mix

# In node2, connect to node1
PeerManager.connect_peer("127.0.0.1", 10200)
```

### Verifying Mesh Formation

```elixir
# Check members on both nodes
PartisanConfig.members()

# Send test message
PartisanConfig.broadcast({:test, :message})

# View connection statistics
PartisanConfig.connection_stats()
```

## Troubleshooting

### Port Already in Use

If port 10200 is taken, update `config/host.exs` or `config/target.exs`:

```elixir
config :partisan,
  listen_addrs: [%{ip: {127, 0, 0, 1}, port: 10201}]
```

### Peers Not Connecting

1. Check firewall rules allow TCP 10200
2. Verify both nodes have Partisan running: `Application.started_applications()`
3. Check logs for connection errors
4. Ensure node names are correctly formatted: `:"name@ip"`

### Memory/Performance Issues

Adjust HyParView parameters in config:

```elixir
config :partisan,
  min_active_size: 2,  # Reduce for smaller deployments
  max_active_size: 4,
  periodic_interval: 30_000  # Less frequent gossip
```

## References

- [Partisan Documentation](https://hexdocs.pm/partisan)
- [HyParView Paper](https://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf)
- [Nerves Networking Guide](https://hexdocs.pm/nerves_pack)
- Project specification: `spec.md`

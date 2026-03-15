# P2P Discovery and RPC System for Nerves

## Overview

A peer-to-peer discovery and communication system for BEAM/Nerves devices operating in low-reliability environments (e.g., construction sites). The system enables autonomous device discovery, mesh networking, and intelligent routing of BEAM RPC calls based on advertised capabilities.

## Problem Context

### Environment
- **Platform**: Nerves (Embedded Elixir/BEAM)
- **Deployment**: Low-reliability areas (construction sites, remote locations)
- **Scale**: Many devices (potentially hundreds)
- **Network**: Unreliable connectivity, devices may be behind NATs

### Challenges
- No guaranteed central server availability
- Network partitions and intermittent connectivity
- NAT traversal requirements
- Dynamic topology changes
- Need for zero-configuration deployment

## Core Requirements

### 1. Peer Discovery
Devices must autonomously discover each other without:
- Central discovery server
- Manual configuration
- Static IP addresses
- DNS infrastructure

**Implementation Considerations:**
- mDNS/DNS-SD for local network discovery
- Gossip protocols for peer propagation
- Periodic heartbeat mechanisms
- Handling network partitions and merges

### 2. Network Communication
Direct device-to-device communication with:
- Low latency for local operations
- Efficient message routing
- Connection pooling and reuse
- Automatic reconnection on failure

**Protocol Requirements:**
- Binary protocol for efficiency
- Message framing and delimiting
- Flow control mechanisms
- Compression for large payloads

### 3. P2P Networking with NAT Traversal
Establish peer-to-peer connections even when devices are behind NATs:
- STUN for NAT type detection
- TURN relay as fallback
- Hole-punching techniques (UDP/TCP)
- Connection preference: direct > relayed > none

**Network Topology:**
- Mesh network with intelligent routing
- Multi-hop message forwarding
- Loop detection and prevention
- Partition tolerance

### 4. Reliable Data Transfer
Ensure data delivery despite unreliable networks:
- Acknowledgment-based delivery confirmation
- Retry logic with exponential backoff
- Message deduplication
- Ordering guarantees (when required)
- Timeout handling

**Quality of Service:**
- Priority queues for critical messages
- Backpressure mechanisms
- Circuit breakers for failing nodes
- Metrics and monitoring hooks

### 5. Capability and Service Advertisement
Devices broadcast their available services and capabilities:
- Service registry (distributed)
- Capability metadata (version, load, status)
- Dynamic capability updates
- Service health checks

**Capability Schema:**
```elixir
%{
  node: :node_name@host,
  services: [:camera, :sensor_data, :processing],
  capabilities: %{
    camera: %{version: "1.0", max_resolution: "1080p"},
    sensor_data: %{types: [:temperature, :humidity], rate: 10},
    processing: %{cpu_available: 0.6, memory_mb: 512}
  },
  metadata: %{
    location: "zone_a",
    priority: :normal,
    last_heartbeat: ~U[2026-03-15 10:30:00Z]
  }
}
```

## Critical BEAM Integration Requirements

### 1. Native BEAM Compatibility
The system MUST maintain full compatibility with BEAM primitives:

**`Node.spawn/2,4` Support:**
- Intercept and route spawn requests
- Maintain process hierarchy semantics
- Support monitors and links across the mesh
- Handle process exit propagation

**`:rpc` Module Support:**
- `rpc.call/4,5` - synchronous RPC with timeout
- `rpc.cast/4` - asynchronous fire-and-forget
- `rpc.multicall/4,5` - parallel calls to multiple nodes
- `rpc.async_call/4` and `rpc.yield/1` - async with later retrieval

**Transparency Goals:**
```elixir
# Should work identically whether target is directly connected or routed
Node.spawn(:remote_node, SomeModule, :function, [args])
:rpc.call(:remote_node, SomeModule, :function, [args], 5000)
```

### 2. Capability-Based Routing
Route BEAM operations based on advertised capabilities, not just node names:

**Routing Strategies:**
- **By node name**: Traditional direct routing
- **By capability**: Route to any node with required capability
- **By service**: Route to specific service type
- **Load-aware**: Route to least-loaded capable node
- **Location-aware**: Route to geographically close node

**Examples:**
```elixir
# Traditional - route to specific node
:rpc.call(:node1@host, Camera, :capture, [])

# Capability-based - route to any node with camera capability
CapabilityRPC.call({:capability, :camera}, Camera, :capture, [])

# Service-based with constraints
CapabilityRPC.call(
  {:service, :camera, %{min_resolution: "720p", location: "zone_a"}},
  Camera,
  :capture,
  []
)

# Load-balanced across all capable nodes
CapabilityRPC.call({:capability, :processing, :load_balanced}, Task, :process, [data])
```

## Architecture Components

### Node Discovery Service
- Listens for mDNS announcements
- Maintains peer list with connection state
- Handles join/leave events
- Publishes local node capabilities

### Connection Manager
- Establishes and maintains connections
- Handles NAT traversal
- Connection health monitoring
- Reconnection logic

### Routing Table
- Distributed hash table (DHT) for node->capability mapping
- Gossip-based synchronization
- Version vectors for conflict resolution
- TTL-based entry expiration

### RPC Proxy Layer
- Intercepts `:rpc` and `Node.spawn` calls
- Resolves capability queries to node addresses
- Multi-hop routing when direct connection unavailable
- Request/response correlation

### Capability Registry
- Local capability advertisement
- Remote capability caching
- Subscription/notification for capability changes
- Query interface for routing decisions

## Technical Decisions

### Transport Protocol
- **Primary**: Distributed Erlang over TLS
- **Alternative**: Custom protocol over QUIC/WebRTC for NAT traversal
- **Fallback**: HTTP/2 or WebSocket through relay

### Discovery Protocol
- **Local**: mDNS (Multicast DNS)
- **Mesh**: Gossip protocol (inspired by SWIM/Memberlist)
- **Bootstrap**: Known seed nodes (optional)

### Data Serialization
- **Internal**: Erlang Term Format (ETF) for BEAM compatibility
- **External**: MessagePack or Protocol Buffers for non-BEAM clients

### State Management
- **Distributed State**: CRDTs for eventual consistency
- **Local State**: ETS for fast lookups
- **Persistence**: Optional DETS/Mnesia for capability history

## Network Topology Scenarios

### Scenario 1: Fully Connected Local Network
All devices on same subnet, direct connectivity.
- Simple broadcast discovery
- Direct peer connections
- Minimal routing overhead

### Scenario 2: Segmented Network with Gateway
Multiple subnets connected via gateway nodes.
- Gateway nodes bridge segments
- Multi-hop routing required
- Capability aggregation at gateways

### Scenario 3: NAT-Separated Clusters
Devices behind different NATs, some with public IPs.
- STUN/TURN for NAT traversal
- Relay nodes with public IPs
- Hybrid direct/relayed connections

### Scenario 4: Partitioned Network
Network split into disconnected segments.
- Partition detection
- Local operation continuation
- Partition healing and state reconciliation

## Failure Modes and Handling

### Node Failure
- Detect via heartbeat timeout
- Remove from routing table
- Retry in-flight requests to alternate nodes
- Notify subscribers of capability loss

### Network Partition
- Continue operating with reachable nodes
- Track vector clocks for state reconciliation
- Merge capability registries on partition heal
- Conflict resolution strategies

### Message Loss
- Application-level acknowledgments
- Configurable retry with exponential backoff
- Dead letter queue for undeliverable messages
- Logging for debugging

### Byzantine Behavior
- Optional signature verification
- Rate limiting per node
- Anomaly detection
- Circuit breakers for misbehaving nodes

## Performance Considerations

### Latency
- Target: <10ms for local network RPC
- Target: <100ms for multi-hop RPC
- Monitoring: P50, P95, P99 latencies

### Throughput
- Target: Handle 1000+ RPC calls/second per node
- Backpressure when queues exceed thresholds
- Message batching for efficiency

### Memory
- Bounded routing table size
- TTL-based capability entry eviction
- Connection pool limits
- Message queue size limits

### Network Bandwidth
- Gossip protocol tuning (interval, fanout)
- Heartbeat frequency optimization
- Compression for large messages
- Delta-based state synchronization

## Security Considerations

### Authentication
- mTLS for node authentication
- Certificate-based identity
- Revocation support

### Authorization
- Capability-based access control
- Service-level permissions
- Rate limiting per node/capability

### Privacy
- Encrypted transport (TLS 1.3)
- Optional message-level encryption
- Capability metadata filtering

## Testing Strategy

### Unit Tests
- Individual component behavior
- Protocol encoding/decoding
- Routing algorithms

### Integration Tests
- Multi-node scenarios
- Capability discovery and routing
- Failure injection

### Property-Based Tests
- Message delivery guarantees
- CRDT convergence
- Partition tolerance

### Load Tests
- Many-node scenarios (100+ nodes)
- High RPC throughput
- Network partition simulation

## Deployment

### Configuration
Zero-configuration by default, with optional overrides:
- Discovery method (mDNS/gossip/seed)
- Network interface binding
- NAT traversal settings
- Capability advertisement

### Monitoring
- Metrics: connection count, RPC latency, message queue depth
- Tracing: distributed request tracing
- Logging: structured logs with correlation IDs
- Dashboards: topology visualization, capability map

### Updates
- Rolling updates support
- Backward compatibility considerations
- Capability version negotiation

## Open Questions

1. How to handle capability versioning and compatibility?
2. What is the maximum acceptable latency for multi-hop RPC?
3. Should we support partial capability matching (fuzzy search)?
4. How to prioritize messages in the routing layer?
5. What metrics are most important for routing decisions?
6. Should we implement request hedging for critical operations?
7. How to handle clock skew in distributed scenarios?

## Success Criteria

- Zero-configuration deployment on new devices
- Sub-100ms P95 latency for capability-based RPC
- Automatic recovery from network partitions within 30 seconds
- Support for 100+ concurrent devices
- Native BEAM interoperability (no code changes for existing RPC)
- 99.9% message delivery success rate in stable network conditions

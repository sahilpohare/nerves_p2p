# Mesh Library — Exploration Notes

Source: https://github.com/sahilpohare/mesh
Cloned to: `/Users/sahilpohare/p2p/p2p_clustering/mesh`

## What It Is

Mesh is a capability-based distributed actor system for Elixir. It routes function invocations to nodes based on *capability* (e.g. `:camera`, `:gpu`) rather than explicit node names. Actors are lazily created, sharded across the cluster, and automatically rebalanced when topology changes.

It has no built-in cluster discovery — it delegates that to `libcluster` and assumes standard Erlang distributed protocol (`Node.connect`, EPMD).

---

## Public API

```elixir
Mesh.call(%Mesh.Request{module: MyActor, id: actor_id, capability: :game, payload: :ping})
Mesh.cast(%Mesh.Request{...})
Mesh.register_capabilities([:camera, :gpu])
Mesh.nodes_for(:camera)           # → [:"node@host"]
Mesh.all_capabilities()           # → %{node => MapSet}
Mesh.shard_for(actor_id)          # → 0..4095
Mesh.owner_node(shard, capability) # → node
```

---

## Architecture

### Three-Layer Routing

```
call(%Request{capability: :game, id: "abc"})
  └─ shard = phash2("abc") mod 4096
  └─ nodes = Capabilities.nodes_for(:game)
  └─ owner = HashStrategy.owner_node(shard, :game, nodes)
  └─ :rpc.call(owner, ActorOwner, :call, [...])
       └─ ActorOwner lazily starts/looks up GenServer for actor_id
```

### Supervision Tree

```
Mesh.Supervisor (one_for_one)
├── ActorTable              (ETS — {capability, module, actor_id} → pid)
├── Registry (ActorRegistry)
├── Registry (ActorOwnerRegistry)
├── Cluster.Capabilities    (GenServer — node→capabilities map)
├── Cluster.Rebalancing     (GenServer — coordinates shard ownership changes)
├── Cluster.Rebalancing.Reconciler  (GenServer — self-heals every 60s)
├── Cluster.Membership      (GenServer — monitors nodeup/nodedown)
├── PartitionSupervisor → ActorSupervisor (DynamicSupervisor per scheduler)
└── ActorOwnerSupervisor    (DynamicSupervisor — one ActorOwner per shard)
```

---

## Key Modules

| Module | File | Role |
|--------|------|------|
| `Mesh` | `lib/mesh.ex` | Public API |
| `Mesh.Actors.ActorSystem` | `actors/actor_system.ex` | Routes requests, handles rebalancing state |
| `Mesh.Actors.ActorOwner` | `actors/actor_owner.ex` | Owns a shard; lazily creates/monitors actors |
| `Mesh.Actors.ActorOwnerSupervisor` | `actors/actor_owner_supervisor.ex` | DynamicSupervisor for ActorOwners; syncs shard assignments |
| `Mesh.Actors.ActorTable` | `actors/actor_table.ex` | ETS-backed actor PID registry |
| `Mesh.Cluster.Capabilities` | `cluster/cluster_capabilities.ex` | Distributed capability registry; propagates via RPC |
| `Mesh.Cluster.Rebalancing` | `cluster/rebalancing.ex` | Coordinates actor migration on topology changes |
| `Mesh.Cluster.Membership` | `cluster/membership.ex` | Handles nodeup/nodedown events |
| `Mesh.Shards.ShardRouter` | `shards/shard_router.ex` | Determines which node owns a shard |
| `Mesh.Shards.HashStrategy` | `shards/hash_strategy.ex` | Behaviour for pluggable shard distribution |

---

## Behaviours / Extension Points

### `Mesh.Shards.HashStrategy`

```elixir
@callback owner_node(shard :: non_neg_integer(), capability :: atom(), nodes :: [node()]) :: node()
```

Default: `EventualConsistency` — `rem(shard, length(nodes))`.
Configurable via `config :mesh, :hash_strategy, MyModule`.

---

## Capability Registry

- Each node calls `Mesh.register_capabilities([:foo, :bar])`
- `Cluster.Capabilities` stores `%{node => MapSet.t(capability)}`
- On registration, capabilities are RPC-broadcast to all connected nodes
- On `nodeup`: propagate existing caps to new node
- On `nodedown`: remove node from map

No DHT, no mDNS — relies entirely on Erlang distribution being already established.

---

## Rebalancing

When nodes join/leave or capabilities change:

1. Capture old shard→node ownership
2. Register new capabilities
3. Compute diff of moved shards
4. Enter rebalancing mode on affected nodes (blocks calls)
5. Stop actors on shards that changed owner
6. Sync shard ownership across cluster
7. Exit rebalancing mode

**Fault tolerance:**
- 50%+ success = proceed (eventual consistency)
- Circuit breaker on repeated failures
- `Reconciler` detects and recovers stuck states every 60s
- RPC retries with exponential backoff

---

## What We Can Borrow

### 1. `HashStrategy` behaviour → our `Registry` behaviour
Their single-callback pluggable shard strategy is the same pattern we want for our pluggable registry. Clean and minimal.

### 2. `ActorTable` (ETS) pattern
Fast ETS-backed lookup table keyed by `{capability, module, id}`. We can adapt this as the backing store for our `Registry.Mock` and `Registry.VintageNet`.

### 3. Capability propagation via RPC broadcast
`Capabilities.propagate_capabilities/2` spawns RPC casts to all nodes on change — simple and effective. We can do the same when VintageNet discovers new peers.

### 4. `nodeup`/`nodedown` via `:net_kernel.monitor_nodes/2`
Clean pattern for detecting topology changes without polling. Relevant if we end up using standard Erlang distribution alongside or instead of Partisan.

### 5. `Rebalancing.Support` — fault-tolerant RPC
Retry logic with exponential backoff, partial success evaluation. Directly applicable to our `Network.spawn` retry strategy.

### 6. Multi-node test pattern (`NodeHelper` + `:peer.start/1`)
Uses OTP 25+ `:peer` module to spin up local peer nodes in tests. Much cleaner than manual `Node.spawn`. We should copy this for our integration tests.

### 7. Lazy actor creation via `ActorOwner`
Rather than pre-registering every possible process, actors are started on first call. Our `Network.spawn` can adopt this — only spawn the remote process when actually needed.

---

## What We Do Differently

| Mesh | elixir_rpc |
|------|------------|
| Assumes nodes already connected (libcluster) | Must discover nodes autonomously (mDNS, VintageNet) |
| Standard Erlang distribution (EPMD) | Partisan overlay OR standard dist |
| Shards by actor ID hash | Route by capability constraints (any matching node) |
| Actors are long-lived, named, rebalanced | `Network.spawn` is fire-and-forget |
| No hardware-awareness | VintageNet drives discovery on embedded targets |
| No NAT traversal | libp2p bridge for NAT/relay |

---

## Suggested Registry Behaviour (inspired by Mesh)

```elixir
defmodule ElixirRpc.Registry do
  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback register(peer_id :: String.t(), capabilities :: map()) :: :ok | {:error, term()}
  @callback unregister(peer_id :: String.t()) :: :ok
  @callback lookup(constraints :: keyword()) :: {:ok, peer_info} | {:error, :not_found}
  @callback list() :: [peer_info]
end
```

Implementations:
- `ElixirRpc.Registry.Mock` — ETS, for `:host`/test (current `MockRegistry`)
- `ElixirRpc.Registry.VintageNet` — listens to VintageNet events, feeds `Discovery`
- `ElixirRpc.Registry.Horde` — Horde.Registry backed, replicated across connected nodes

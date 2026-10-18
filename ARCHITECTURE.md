# Architecture

## Decision

The canonical runtime is:

```text
Iroh capability discovery
            |
Partisan membership and messaging
            |
Horde registry and supervision
            |
Application workers
```

Each concern has one owner. New code must not add another discovery registry,
RPC facade, membership service, or distributed supervisor.

## Library Boundary

`elixir_rpc` is a library, not an application. `config :elixir_rpc, network_mode`
selects what `ElixirRpc.Application` starts:

- `:none` (default) — starts nothing. The consumer supervises Iroh, Partisan,
  and Horde itself, or doesn't use them at all.
- `:iroh` — starts `ElixirRpc.IrohDiscovery.Port` and, on top of it, Horde's
  registry and dynamic supervisor over the Partisan adapters below.
- `:legacy` — starts the transitional libp2p stack (see Non-Goals).

Nerves firmware config (`rootfs_overlay`, target networking, `rel/`) and the
talk demo (`talk_web`, `talk_worker`, `mix talk.demo`/`talk.ui`) live under
`examples/`, not in `lib/`. They are not part of the published package.

## Iroh

Iroh operates before Partisan membership exists.

Responsibilities:

- Persistent endpoint identity
- Fleet bootstrap
- Signed capability gossip
- Signed publication of the selected peer's Partisan LAN endpoint

Address lookup composes explicit bootstrap addresses, provisioned endpoint IDs,
DNS/Pkarr, local mDNS, Mainline DHT, and relay/direct transport. DHT and DNS
resolve addresses for known endpoint IDs; Iroh Gossip carries capabilities.

Iroh does not execute Erlang terms or supervise application processes.

## Partisan

Partisan is the only BEAM message and membership layer.

Responsibilities:

- Peer membership
- Failure detection
- Horde transport
- Sparse topology through bounded HyParView active and passive views

Application code does not add a second custom RPC protocol. Existing libp2p
request-response modules are transitional and will be deleted after Iroh can
open the selected Partisan connection.

Horde does not ship Partisan support, so `ElixirRpc.Horde.PartisanTransport`
and `ElixirRpc.Horde.PartisanNodeListener` (`lib/elixir_rpc/horde/`) are
vendored adapters, not upstream Horde modules. They are the `transport` and
`members` Horde is configured with; nothing else bridges Horde to Partisan.

## Horde

Horde is the only distributed process registry and supervisor.

Responsibilities:

- Distributed names
- Child placement
- Restart and duplicate suppression
- Placement on the node selected by capability discovery

`ElixirRpc.Network.Handoff` is the application boundary. It waits for the
selected Partisan/Horde member and submits a uniquely identified child spec.

Horde's distribution strategy is `ElixirRpc.Network.CapabilityDistributionStrategy`
(`@behaviour Horde.DistributionStrategy`). `choose_node/2` branches on
`child_spec.meta.cdp_target_node`:

- **Set** (by `Handoff`, see below) — pin to that exact alive member, or
  error `"target node is not an alive Horde member: ..."` if it isn't yet.
  `Handoff` treats that specific error string as `{:error, :peer_unavailable}`
  and retries until its deadline, because a node that just joined Partisan is
  listed by `Horde.Cluster.members/1` before Horde marks it `:alive`.
- **Unset** — route by `child_spec.meta.requires`, a list of modules. Every
  node advertises its `:code.all_loaded/0` into `Horde.Registry` under
  `{node(), :modules}` via `ElixirRpc.Network.ModuleRegistry` (CRDT-replicated,
  so every node already has every other node's module list — no cross-node
  RPC at placement time). Candidates are alive members whose advertised set
  is a superset of `:requires`; the final pick is HashRing-consistent over
  `child_spec` minus `:id`, so the same spec maps to the same node as
  membership is stable. Empty `:requires` means any alive node.

These are two independent ways to reach Horde placement — one driven by a
fresh Iroh/Partisan join (`Network.spawn/2`, `Network.start_child/3`), the
other usable inside an already-formed cluster with no discovery step at all
(`Horde.DynamicSupervisor.start_child/2` with `meta: %{requires: [...]}}`
directly, or `ElixirRpc.Network.Task.async/1` for ad-hoc work).

## Code Identity

`ElixirRpc.CodeIdentity` ties placement to exact compiled code, not just a
capability name. `entry/1` hashes a module's BEAM code
(`module.module_info(:md5)`) into `"Mod:md5hex"`; `advertised/0` returns one
entry per module in `config :elixir_rpc, :placeable_modules` (default
`[ElixirRpc.DemoWorker]`). Those entries are published under the `"code"` key
of the node's CDP capability map (an entry is a `contains` match on that
list, so every advertised module is independently queryable), which is why
`Network.spawn/2` can require `CodeIdentity.requirement(module)` — it refuses
to place work on a peer unless the peer's *signed* record proves it already
holds byte-identical code for that module. The CDP capability map caps at 32
entries; today's `:placeable_modules` default comfortably fits, but a larger
module set needs the single-manifest-hash change the `# ponytail:` comment in
that file calls out.

## Capability Flow

`Network.spawn/2` and `Network.start_child/3` (`lib/elixir_rpc/network.ex`) are
the join-from-scratch path:

```text
device signs CDP announcement
-> Iroh gossip broadcasts it
-> local registry verifies identity, sequence and TTL
-> ElixirRpc.IrohDiscovery.Port "find" queries the local registry by
   predicate (equals / at_least / contains over the capability map,
   including the "code" entries above)
-> first matching peer's node_name is checked against the caller's
   :authorized_nodes map (config, not the CDP record) -> a Partisan
   node name
-> :partisan_peer_service.join/1 on that peer's advertised
   partisan_ip/partisan_port, unless already a member
-> ElixirRpc.Network.Handoff waits for Horde.Cluster.members/1 to list
   that node, then Horde.DynamicSupervisor.start_child/2 with
   meta.cdp_target_node set, retrying on :peer_unavailable until timeout
-> CapabilityDistributionStrategy pins the child to that exact node
```

`:authorized_nodes` is deliberately separate from CDP enrollment: CDP
authorizes a signed announcement, this map authorizes *this caller* to join
that resulting Partisan node name. Both checks must pass.

Capability records and invariants are defined in
`IROH_CAPABILITY_PROTOCOL.md`. `ElixirRpc.IrohDiscovery.Port` is a `Port`-based
GenServer wrapping the `iroh_discovery_port` executable over a length-prefixed
JSON-RPC-like protocol (`identity`, `authorize`, `network_start`, `publish`,
`ingest`, `find`, plus `dist_*` commands for the experimental Partisan-over-Iroh
tunnel); `subscribe/2` delivers out-of-band `{:iroh_dist, event}` messages for
async gossip events (peer seen, peer expired) outside the request/reply cycle.

## Public Surface

The intended application API is deliberately small:

```elixir
ElixirRpc.Network.capabilities()
ElixirRpc.Network.advertise(capabilities)
ElixirRpc.Network.spawn(requirements, {module, fun, args})
ElixirRpc.Network.start_child(requirements, child_spec, opts)
```

`requirements` is a map of `name => value | {:at_least, n} | {:contains, v}`,
compiled to CDP query predicates. Everything else — `Handoff`, the
distribution strategy, `ModuleRegistry`, `CodeIdentity`, the Horde/Partisan
adapters in `lib/elixir_rpc/horde/` — is placement machinery an application
should not call directly.

## Non-Goals

- Reimplementing Distributed Erlang
- A second actor runtime alongside Horde
- Arbitrary transport-specific APIs in application code
- DHT and gossip implementations for the same capability records
- Keeping legacy libp2p APIs after Iroh replacement is complete

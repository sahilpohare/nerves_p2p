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

## Horde

Horde is the only distributed process registry and supervisor.

Responsibilities:

- Distributed names
- Child placement
- Restart and duplicate suppression
- Placement on the node selected by capability discovery

`ElixirRpc.Network.Handoff` is the application boundary. It waits for the
selected Partisan/Horde member and submits a uniquely identified child spec.

## Capability Flow

```text
device signs CDP announcement
-> Iroh gossip broadcasts it
-> local registry verifies identity, sequence and TTL
-> query filters and orders candidates
-> Partisan joins the selected signed LAN endpoint into its HyParView
-> Horde observes the member
-> Handoff starts the child on that exact node
```

Capability records and invariants are defined in
`IROH_CAPABILITY_PROTOCOL.md`.

## Public Surface

The intended application API is deliberately small:

```elixir
ElixirRpc.Network.start_child(requirements, child_spec)
ElixirRpc.Network.capabilities()
```

Everything else is transport or supervision internals.

## Non-Goals

- Reimplementing Distributed Erlang
- A second actor runtime alongside Horde
- Arbitrary transport-specific APIs in application code
- DHT and gossip implementations for the same capability records
- Keeping legacy libp2p APIs after Iroh replacement is complete

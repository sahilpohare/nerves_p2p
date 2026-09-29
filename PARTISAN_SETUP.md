# Partisan And Horde

Partisan is the BEAM membership and message layer. Horde uses its merged
Partisan adapters for registry and supervisor membership.

The configured peer service is `partisan_hyparview_peer_service_manager`, with
an active view bounded at six peers and a passive view bounded at thirty. Iroh
capability discovery finds candidates globally; joining the selected signed
endpoint promotes the exact work target into the sparse Partisan overlay.

```elixir
{Horde.Registry,
 name: ElixirRpc.Registry,
 keys: :unique,
 members: {:auto, Horde.NodeListener.Partisan},
 transport: Horde.ClusterTransport.Partisan}

{Horde.DynamicSupervisor,
 name: ElixirRpc.DynamicSupervisor,
 strategy: :one_for_one,
 members: {:auto, Horde.NodeListener.Partisan},
 distribution_strategy: ElixirRpc.Network.CapabilityDistributionStrategy}
```

Iroh capability announcements carry the signed Partisan node name, IPv4
address, and listener port. `ElixirRpc.Network.start_child/3` joins that peer
and hands the uniquely identified child specification to Horde.

For the talk demo:

```bash
cargo build --manifest-path native/iroh_discovery/Cargo.toml
mix talk.demo
```

Partisan does not provide NAT traversal. The talk demo is intentionally scoped
to directly reachable LAN endpoints.

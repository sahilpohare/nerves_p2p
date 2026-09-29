# Elixir RPC

Capability-based process placement for Nerves devices.

The project has three layers:

- **Iroh** discovers authorized devices and their capabilities before joining.
- **Partisan** provides membership and message transport between BEAM nodes.
- **Horde** owns distributed registry and process supervision.

See `ARCHITECTURE.md` for boundaries and `IROH_CAPABILITY_PROTOCOL.md` for the
signed discovery protocol. Older libp2p documents describe the implementation
being replaced and are not architecture references.

## Current Status

- Horde starts over its merged Partisan transport adapters.
- Capability-selected Horde placement and bounded handoff are tested.
- Iroh capability records have four Hoare-contract tests.
- Two local Iroh endpoints exchange and verify a capability announcement.
- The existing libp2p runtime remains active until the Iroh Port and Partisan
  tunnel are proven end to end.

## Development

```bash
mix deps.get
mix test

cd native/iroh_discovery
cargo test
```

## Talk Demo

```bash
cargo build --manifest-path native/iroh_discovery/Cargo.toml
mix talk.demo
```

The command runs two real Iroh daemon processes for signed capability discovery,
then demonstrates the selected child specification through local Horde. It
labels local placement explicitly; remote Partisan/Horde placement is the next
demo milestone.

### Browser Dashboard

```bash
mix talk.ui
# open http://127.0.0.1:4000
```

Pass a different port with `mix talk.ui 4100`. Press `R` or select **Run Demo**
to stream the real discovery and placement stages into the dashboard.

For the laptop plus Nerves Raspberry Pi 4 sequence, follow `TALK_RUNBOOK.md`.

## Target Demo

A constrained Nerves node discovers a GPU node by signed capability metadata,
establishes connectivity, and asks Horde to place a VLM worker on that node.

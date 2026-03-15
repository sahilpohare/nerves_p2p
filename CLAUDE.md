# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Nerves-based Elixir project implementing a peer-to-peer discovery and RPC system for BEAM devices in low-reliability environments (e.g., construction sites). The system enables autonomous device discovery, mesh networking, and capability-based routing of BEAM RPC calls.

**Key Goals:**
- Zero-configuration P2P discovery without central servers
- NAT traversal for devices behind firewalls
- Capability-based intelligent routing (route to "any camera" vs specific nodes)
- Native BEAM compatibility (transparent `Node.spawn/2,4` and `:rpc` module support)
- Resilience to network partitions and unreliable connectivity

See `spec.md` for comprehensive system requirements and architecture details.

## Project Structure

This is a standard Nerves project with target-specific configurations:

- **`lib/elixir_rpc.ex`**: Main module (currently minimal placeholder)
- **`lib/elixir_rpc/application.ex`**: OTP application supervisor
- **`config/config.exs`**: Base configuration
- **`config/host.exs`**: Host/development environment config
- **`config/target.exs`**: Embedded device target config (networking, SSH, mDNS)
- **`spec.md`**: Complete system specification and architecture

## Common Commands

### Development (Host Target)

The project defaults to building for `:host` (your development machine) when `MIX_TARGET` is not set.

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Start IEx session
iex -S mix

# Format code
mix format

# Run single test file
mix test test/elixir_rpc_test.exs

# Run specific test
mix test test/elixir_rpc_test.exs:10
```

### Building for Hardware Targets

Supported targets: `:bbb`, `:grisp2`, `:osd32mp1`, `:mangopi_mq_pro`, `:qemu_aarch64`, `:rpi`, `:rpi0`, `:rpi0_2`, `:rpi2`, `:rpi3`, `:rpi4`, `:rpi5`, `:x86_64`

```bash
# Set target for all subsequent commands
export MIX_TARGET=rpi4

# Or prefix individual commands
MIX_TARGET=rpi4 mix deps.get
MIX_TARGET=rpi4 mix firmware

# Create firmware image
mix firmware

# Burn to SD card (interactive prompt for device)
mix burn

# Upload firmware to running device over SSH
mix upload nerves.local
```

### Working with Nerves Devices

```bash
# SSH into device
ssh nerves.local

# Check firmware info on device (from IEx)
Nerves.Runtime.KV.get_all_active()

# Reboot device (from IEx)
Nerves.Runtime.reboot()
```

## Architecture Notes

### Target-Specific Behavior

The application uses compile-time conditionals based on `Mix.target()`:

- **`:host` target**: Used for development and testing on your machine. The supervisor in `application.ex` starts different children via `target_children/0`.
- **Other targets**: Embedded device mode with full Nerves stack including networking, SSH, and mDNS discovery.

### Key Dependencies

- **`nerves`**: Embedded framework for building firmware
- **`nerves_pack`**: Networking utilities (vintage_net, mdns_lite, nerves_ssh)
- **`nerves_runtime`**: Runtime utilities for firmware management
- **`shoehorn`**: Application boot ordering and failure handling
- **`ring_logger`**: In-memory circular log buffer (replaces console logger on devices)
- **`toolshed`**: IEx helpers for embedded development

### Configuration Details

**Host mode** (`config/host.exs`):
- Uses in-memory KV backend for simulating Nerves.Runtime.KV
- Suitable for unit testing and local development

**Target mode** (`config/target.exs`):
- Configures networking: `usb0`, `eth0` (DHCP), `wlan0` (WiFi)
- Sets up mDNS for discovery at `nerves.local` and `<hostname>.local`
- Enables SSH access (requires SSH public keys in `~/.ssh/`)
- Advertises services: SSH (22), EPMD (4369)
- Uses RingLogger instead of console logger
- Enables firmware rollback guard via `startup_guard_enabled`

### mDNS and Discovery

The project already configures `mdns_lite` to advertise services. This is foundational for the P2P discovery system described in `spec.md`. When implementing discovery features, extend the `services` list in `config/target.exs` to advertise custom capability metadata.

## Implementation Status

**Current State**: Scaffolded Nerves project with basic infrastructure.

**Not Yet Implemented** (per `spec.md`):
- Peer discovery service (mDNS listener, gossip protocol)
- Connection manager (NAT traversal, STUN/TURN)
- Routing table (DHT, capability registry)
- RPC proxy layer (intercept `:rpc` and `Node.spawn`)
- Capability advertisement and query system
- Multi-hop routing and mesh networking

When implementing these components, follow the architecture outlined in `spec.md` sections on "Architecture Components" and "Technical Decisions".

## Key Design Constraints

1. **BEAM Native Compatibility**: Any RPC routing must be transparent to existing `:rpc.call/4,5`, `:rpc.cast/4`, `Node.spawn/2,4` calls. Consider using process dictionary, distributed Erlang hooks, or custom node connection logic.

2. **Capability-Based Routing**: The system must support routing based on capabilities (e.g., "any node with a camera") not just node names. Design the routing table and capability registry with query interfaces.

3. **Zero Configuration**: Devices must discover each other autonomously. Leverage mDNS (already configured) and implement gossip protocols for mesh propagation.

4. **Partition Tolerance**: Use CRDTs or version vectors for distributed state that tolerates network splits and merges gracefully.

5. **Nerves Constraints**: Embedded devices have limited resources. Bound routing table sizes, use ETS for fast lookups, and implement TTL-based eviction.

## Testing Approach

- **Unit tests**: Individual components (routing algorithms, protocol encoding)
- **Integration tests**: Multi-node scenarios using distributed Erlang or ExUnit's `:peer` nodes
- **Property-based tests**: Use StreamData for CRDT convergence, message delivery guarantees
- **Hardware tests**: Deploy to actual Nerves devices for NAT traversal and real-world network conditions

For multi-node tests, start peer nodes in test setup and verify discovery, capability advertisement, and RPC routing behavior.

## Debugging and Monitoring

On device (IEx):
```elixir
# View logs
RingLogger.attach()

# Network info
Toolshed.ifconfig()

# Running processes
:observer.start()  # May not work on all Nerves systems

# mDNS advertised services
MdnsLite.Responder.services()
```

## Deployment Notes

- **SSH Keys**: Before burning firmware, ensure you have SSH public keys in `~/.ssh/` or the build will fail (see `config/target.exs:39-45`)
- **Regulatory Domain**: Update `regulatory_domain` in `config/target.exs` for WiFi compliance (currently set to "00")
- **Hostname Conflicts**: If multiple devices are on the same network, remove `"nerves"` from `mdns_lite.hosts` to avoid conflicts
- **Firmware Updates**: Use `mix upload <hostname>.local` for over-the-air updates via SSH
- **Rollback**: Nerves systems support automatic rollback if the new firmware fails health checks (enabled via `startup_guard_enabled`)

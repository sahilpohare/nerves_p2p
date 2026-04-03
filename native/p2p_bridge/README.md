# P2P Bridge - Rust libp2p for Elixir

A Rust libp2p bridge for Elixir/Nerves that runs as a safe external Port process.

## Features

- **Automatic Discovery**: mDNS for local network peer discovery
- **NAT Traversal**: AutoNAT, UPnP, STUN, relay, and hole-punching (DCUtR)
- **Dynamic Ports**: OS assigns available ports automatically
- **Multi-Protocol**: TCP, QUIC support
- **Safe for Embedded**: Runs as external process (not a NIF)
- **Cross-Platform**: Compiles for all Nerves targets

## Architecture

```
┌─────────────────┐         JSON over          ┌──────────────────┐
│   Elixir BEAM   │◄────── stdin/stdout ──────►│  Rust libp2p     │
│  (supervised)   │                             │   (Port process) │
└─────────────────┘                             └──────────────────┘
         │                                               │
         │                                               │
         ▼                                               ▼
  Partisan Mesh                              libp2p Network
  (RPC routing)                              (Discovery, NAT)
```

### Why Port vs NIF?

- **Safety**: Port crashes don't crash BEAM VM
- **Isolation**: Separate memory space
- **Supervisable**: OTP can restart the Port
- **Embedded-Safe**: Critical for Nerves devices

## Building

### For Development (Host)

```bash
cd native/p2p_bridge
./build.sh
```

### For Nerves Targets

```bash
# Raspberry Pi 4 (AArch64)
MIX_TARGET=rpi4 ./build.sh

# Raspberry Pi Zero (ARMv7)
MIX_TARGET=rpi0 ./build.sh

# x86_64
MIX_TARGET=x86_64 ./build.sh
```

## Cross-Compilation Setup

### Install Rust Targets

```bash
# ARMv7 (RPi 1/2/Zero, BeagleBone)
rustup target add armv7-unknown-linux-gnueabihf

# AArch64 (RPi 3/4/5)
rustup target add aarch64-unknown-linux-gnu

# x86_64 musl (static linking)
rustup target add x86_64-unknown-linux-musl
```

### Install Cross-Compilers (macOS)

```bash
# Using Homebrew
brew install arm-linux-gnueabihf-binutils
brew install aarch64-linux-gnu-binutils

# Or use cross-rs (recommended)
cargo install cross
```

### Using cross-rs (Easier)

Instead of installing toolchains manually, use `cross`:

```bash
cargo install cross

# Build for any target:
cross build --release --target armv7-unknown-linux-gnueabihf
cross build --release --target aarch64-unknown-linux-gnu
```

## Protocol

### Commands (Elixir → Rust)

JSON messages sent to stdin, one per line:

```json
{"type": "get_peer_id"}
{"type": "get_listen_addrs"}
{"type": "dial", "multiaddr": "/ip4/192.168.1.100/tcp/4001"}
{"type": "get_connected_peers"}
{"type": "ping"}
```

### Events (Rust → Elixir)

JSON messages from stdout, one per line:

```json
{"type": "peer_id", "peer_id": "12D3KooW..."}
{"type": "listening_on", "multiaddr": "/ip4/192.168.1.50/tcp/54321"}
{"type": "peer_discovered", "peer_id": "...", "multiaddr": "...", "protocol": "mdns"}
{"type": "nat_status", "status": "public:1.2.3.4"}
{"type": "upnp_mapped", "external_addr": "/ip4/1.2.3.4/tcp/54321"}
{"type": "connection_established", "peer_id": "...", "multiaddr": "..."}
{"type": "connection_closed", "peer_id": "..."}
```

## Usage from Elixir

```elixir
# Start the bridge
{:ok, _pid} = ElixirRpc.Libp2pBridge.start_link()

# Get peer ID
peer_id = ElixirRpc.Libp2pBridge.get_peer_id()

# Get listen addresses (with OS-assigned ports)
addrs = ElixirRpc.Libp2pBridge.get_listen_addrs()

# Dial a peer
ElixirRpc.Libp2pBridge.dial("/ip4/192.168.1.100/tcp/4001")

# Get connected peers
peers = ElixirRpc.Libp2pBridge.get_connected_peers()

# Check NAT status
nat_status = ElixirRpc.Libp2pBridge.get_nat_status()
# => :public | :private | :unknown
```

## Integration with Partisan

The libp2p bridge provides NAT traversal and discovery information to Partisan:

1. **Discovery**: libp2p mDNS discovers peers on LAN
2. **NAT Info**: AutoNAT detects if node is behind NAT
3. **Public Addresses**: UPnP/STUN provides external addresses
4. **Relay**: Acts as STUN server for Partisan connections

Partisan uses this information to establish direct connections or use relays.

## Troubleshooting

### Binary not found

```
** (RuntimeError) Could not find p2p_bridge binary
```

Solution: Build the Rust project first:
```bash
cd native/p2p_bridge && cargo build --release
```

### Cross-compilation errors

If using `cross`, make sure Docker is running:
```bash
docker info
cross build --target armv7-unknown-linux-gnueabihf
```

### Port closes immediately

Check logs in Elixir for error messages. Common issues:
- Missing dependencies
- Wrong architecture binary
- Port conflict

## Performance

- **Memory**: ~10-20MB (Rust process)
- **CPU**: Minimal when idle, spikes during discovery
- **Network**: mDNS broadcasts every ~60s

## Security

- **Authentication**: Ed25519 peer identity
- **Encryption**: Noise protocol for all connections
- **No NIFs**: Safe for production embedded devices

# libp2p Integration for P2P RPC System

## Overview

This project now uses **Rust libp2p** as a safe, external Port process to handle:
- **Peer Discovery** (mDNS, Kademlia DHT)
- **NAT Traversal** (AutoNAT, UPnP, STUN, DCUtR hole-punching)
- **Dynamic Port Assignment** (OS assigns available ports)
- **Relay Services** (Acts as STUN/relay for other nodes)

The libp2p bridge runs as a **supervised Port process**, which is safe for embedded Nerves devices (no NIFs that can crash the BEAM VM).

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    BEAM VM (Elixir)                        │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  ┌──────────────────┐         ┌──────────────────┐       │
│  │  Partisan Mesh   │         │  PeerManager     │       │
│  │  (RPC Routing)   │◄───────►│  (Orchestrator)  │       │
│  └──────────────────┘         └─────────┬────────┘       │
│                                          │                 │
│                                          ▼                 │
│                               ┌──────────────────┐        │
│                               │ Libp2pBridge     │        │
│                               │ (Port Supervisor)│        │
│                               └─────────┬────────┘        │
└──────────────────────────────────────────│──────────────────┘
                                           │ JSON stdin/stdout
                  ┌────────────────────────┴────────────────┐
                  │   External OS Process (Safe)            │
                  ├─────────────────────────────────────────┤
                  │         Rust libp2p (p2p_bridge)        │
                  │  - mDNS discovery                        │
                  │  - AutoNAT (detect NAT type)            │
                  │  - UPnP (automatic port forwarding)     │
                  │  - Relay (STUN for Partisan)            │
                  │  - DCUtR (hole punching)                │
                  │  - Gossipsub, Kademlia DHT              │
                  └─────────────────────────────────────────┘
```

## Key Components

### 1. Rust libp2p Bridge (`native/p2p_bridge/`)

**Location**: `native/p2p_bridge/src/`

**What it does**:
- Runs as standalone binary (not a NIF)
- Communicates via JSON over stdin/stdout
- Discovers peers on local network (mDNS)
- Detects NAT status (AutoNAT)
- Maps external ports (UPnP)
- Provides relay/STUN for Partisan
- OS assigns ports dynamically

**Why Port and not NIF**:
- ✅ Safe - Port crashes don't crash BEAM
- ✅ Isolated - Separate memory space
- ✅ Supervisable - OTP can restart it
- ✅ Embedded-safe - Critical for Nerves

### 2. Elixir Bridge (`lib/elixir_rpc/libp2p_bridge.ex`)

**Responsibilities**:
- Spawns and supervises the Rust Port process
- Sends commands (dial, get_peers, etc.)
- Receives events (peer_discovered, connection_established, etc.)
- Exposes clean Elixir API

**API**:
```elixir
ElixirRpc.Libp2pBridge.get_peer_id()         # Get local libp2p PeerID
ElixirRpc.Libp2pBridge.get_listen_addrs()    # Get actual ports assigned
ElixirRpc.Libp2pBridge.dial(multiaddr)       # Connect to peer
ElixirRpc.Libp2pBridge.get_connected_peers() # List connections
ElixirRpc.Libp2pBridge.get_nat_status()      # :public | :private | :unknown
```

### 3. PeerManager Integration

**Updated Role**:
- Receives peer discovery events from libp2p
- Extracts connection info (IP, ports)
- Passes to Partisan for mesh formation
- Monitors NAT status for routing decisions

## Dynamic Port Assignment

**Problem**: Hardcoded port 10200 causes conflicts when multiple nodes run on same host.

**Solution**: libp2p uses OS-assigned ports:

1. Rust binary listens on `0.0.0.0:0` (OS picks port)
2. libp2p reports actual port via `listening_on` event
3. Elixir reads the assigned port
4. Advertises via mDNS with actual port
5. Partisan uses this port for connections

**Example**:
```
Node 1: libp2p on 192.168.1.50:54321, Partisan uses this
Node 2: libp2p on 192.168.1.51:54322, Partisan uses this
```

## NAT Traversal

### AutoNAT
Detects if node is behind NAT:
- **Public**: Direct connections possible
- **Private**: Need relay or hole-punching
- **Unknown**: Still probing

### UPnP
Automatically forwards ports on routers that support UPnP:
```
Local:  192.168.1.50:54321
Router: 1.2.3.4:54321 → 192.168.1.50:54321
```

### Relay + DCUtR
For symmetric NATs:
1. Connect via relay server (another peer)
2. Attempt hole-punching (DCUtR)
3. Upgrade to direct connection if successful
4. Fall back to relay if hole-punching fails

## Discovery Flow

1. **libp2p mDNS** discovers peers on LAN
2. **Libp2pBridge** receives `peer_discovered` events
3. **PeerManager** extracts IP/port from multiaddr
4. **Partisan** joins peer to mesh using extracted address
5. **Mesh forms** with NAT-aware routing

## Building

### Development (Host)
```bash
cd native/p2p_bridge
./build.sh
```

### Nerves Targets
```bash
# Raspberry Pi 4
MIX_TARGET=rpi4 ./build.sh

# Raspberry Pi Zero
MIX_TARGET=rpi0 ./build.sh
```

### Cross-Compilation Setup

**Install Rust targets**:
```bash
rustup target add armv7-unknown-linux-gnueabihf  # RPi 1/2/Zero
rustup target add aarch64-unknown-linux-gnu      # RPi 3/4/5
```

**Option 1: Install toolchains** (macOS):
```bash
brew install arm-linux-gnueabihf-binutils
brew install aarch64-linux-gnu-binutils
```

**Option 2: Use `cross`** (easier):
```bash
cargo install cross
cross build --release --target armv7-unknown-linux-gnueabihf
```

## Protocol (Port Communication)

### Commands (Elixir → Rust)
```json
{"type": "get_peer_id"}
{"type": "dial", "multiaddr": "/ip4/192.168.1.100/tcp/54321"}
{"type": "get_connected_peers"}
```

### Events (Rust → Elixir)
```json
{"type": "peer_discovered", "peer_id": "12D3KooW...", "multiaddr": "/ip4/192.168.1.100/tcp/54321", "protocol": "mdns"}
{"type": "listening_on", "multiaddr": "/ip4/0.0.0.0/tcp/54321"}
{"type": "nat_status", "status": "public:1.2.3.4"}
{"type": "upnp_mapped", "external_addr": "/ip4/1.2.3.4/tcp/54321"}
{"type": "connection_established", "peer_id": "...", "multiaddr": "..."}
```

## Integration with Partisan

### Before (Hardcoded Ports)
```elixir
# Problem: Port conflicts
config :partisan,
  listen_addrs: [%{ip: {0, 0, 0, 0}, port: 10200}]  # Fixed port
```

### After (Dynamic Discovery)
```elixir
# libp2p discovers peer:
# PeerID: 12D3KooW... at /ip4/192.168.1.100/tcp/54321

# Extract info and join via Partisan:
PartisanConfig.join_peer(%{
  name: :"elixir_rpc@192.168.1.100",
  listen_addrs: [%{ip: {192, 168, 1, 100}, port: 54321}]
})
```

### STUN/Relay for Partisan
libp2p provides:
- **Public addresses** from AutoNAT/UPnP
- **Relay endpoints** for NAT traversal
- **Connection info** for routing decisions

Partisan uses this to:
- Prefer direct connections when possible
- Use relay for nodes behind symmetric NAT
- Make intelligent routing decisions

## Testing

### Start libp2p bridge
```bash
# Build first
cd native/p2p_bridge && ./build.sh

# Start Elixir with libp2p
iex -S mix
```

### Test discovery
```elixir
# Get peer ID
ElixirRpc.Libp2pBridge.get_peer_id()
# => "12D3KooWABC..."

# Get listen addresses (with actual OS-assigned ports)
ElixirRpc.Libp2pBridge.get_listen_addrs()
# => ["/ip4/192.168.1.50/tcp/54321", "/ip6/::1/tcp/54321"]

# Check NAT status
ElixirRpc.Libp2pBridge.get_nat_status()
# => :public | :private | :unknown

# Get discovered peers
ElixirRpc.Libp2pBridge.get_discovered_peers()
```

## Benefits

1. **No Port Conflicts**: OS assigns available ports
2. **NAT Traversal**: Works behind routers/firewalls
3. **Safety**: Port process can't crash BEAM
4. **Discovery**: mDNS finds peers automatically
5. **Cross-Platform**: Compiles for all Nerves targets
6. **Battle-Tested**: libp2p is production-grade

## Next Steps

- [x] Rust libp2p Port implementation
- [x] Elixir Bridge GenServer
- [x] Cross-compilation for Nerves
- [ ] Update PeerManager to use libp2p events
- [ ] Remove hardcoded Partisan ports
- [ ] Test multi-node mesh formation
- [ ] Add relay prioritization logic
- [ ] Performance tuning for embedded

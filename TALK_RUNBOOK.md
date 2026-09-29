# Raspberry Pi Talk Demo Runbook

## What The Demo Proves

The Raspberry Pi 4 publishes a signed `gpu: true` capability and its Partisan
endpoint. The laptop discovers it through Iroh, verifies the record, joins the
Partisan peer, and asks Horde to place a worker on the selected node.

Iroh enables all available address paths:

- Explicit bootstrap address fallback
- Provisioned bootstrap endpoint IDs
- DNS/Pkarr lookup
- Local mDNS enumeration
- BitTorrent Mainline DHT lookup
- Direct QUIC, NAT traversal, and relay fallback

The DHT resolves known endpoint IDs; capability records travel over Iroh Gossip.

## Network Scope

For the complete discovery plus Horde placement demo, keep the laptop and Pi on
the same routable LAN. Iroh discovery works over the internet, but Partisan TCP
does not yet tunnel through Iroh, so remote placement across separate NATs is
not part of this runbook.

## Shared Value

Use the same fleet ID in every command:

```bash
export IROH_FLEET_ID=0707070707070707070707070707070707070707070707070707070707070707
```

Use a fresh random 64-character hexadecimal value outside the talk rehearsal.

## Terminal 1: Build The Raspberry Pi Firmware

```bash
cd /Users/sahilpohare/p2p/p2p_clustering/elixir_rpc
MIX_TARGET=rpi4 mix deps.get
./scripts/build_iroh_rpi4.sh
```

Captured output:

```text
Finished `release` profile [optimized] target(s) in 0.52s
Built rootfs_overlay/usr/bin/iroh_discovery_port
```

Build firmware:

```bash
MIX_TARGET=rpi4 MIX_ENV=prod mix firmware
```

Captured output:

```text
Building .../_build/rpi4_prod/nerves/images/elixir_rpc.fw...
Firmware built successfully!
```

Install the firmware:

```bash
MIX_TARGET=rpi4 MIX_ENV=prod mix burn
```

Insert the card and boot the Raspberry Pi with Ethernet connected to the same
LAN as the laptop.

## Terminal 2: Verify The Raspberry Pi Worker

Connect after the Pi boots:

```bash
ssh nerves.local
```

At the IEx prompt:

```elixir
ElixirRpc.TalkWorker.status()
```

Expected shape on the physical device:

```elixir
%{
  capabilities: %{"gpu" => true},
  network: %{
    "discovery_mechanisms" => ["mdns", "dht", "dns", "relay"],
    "endpoint_address" => %{
      "endpoint_id" => "<persistent Pi endpoint ID>",
      "direct_addresses" => ["<Pi LAN IP>:<Iroh UDP port>"]
    }
  },
  publish_count: 1,
  last_publish: {:ok, %{"sequence" => 1, "envelope" => "<signed record>"}}
}
```

`publish_count` increases every three seconds.

## Terminal 3: Start The Laptop Dashboard

Build the host daemon once:

```bash
cargo build --manifest-path native/iroh_discovery/Cargo.toml
```

Start remote-device mode:

```bash
export TALK_DEMO_MODE=remote
mix talk.ui
```

Captured startup output:

```text
Running ElixirRpc.TalkWeb.Router with Bandit at 127.0.0.1:4000 (http)
Talk dashboard: http://127.0.0.1:4000
```

Open:

```text
http://127.0.0.1:4000
```

Select `RUN DEMO` or press `R`.

## What You Should See

The event tape should progress through:

```text
STAGE      DISCOVER REMOTE RASPBERRY PI
ATTEMPT    Looking for remote Raspberry Pi GPU
VERIFIED   Remote Raspberry Pi capability record verified
PEER       selected remote Raspberry Pi: gpu@nerves.local at <Pi IP>:<Partisan port>
STAGE      PARTISAN JOIN AND HORDE HANDOFF TO REMOTE RASPBERRY PI
RESULT     remote Raspberry Pi result: {:demo_result, ...}
```

The selected peer panel should show:

```text
CAPABILITY  gpu = true
SEQUENCE    <positive integer>
PLACEMENT   remote Raspberry Pi
```

## Internet Lookup Fallback

If mDNS is unavailable but the Pi has internet access, copy its persistent
endpoint ID once from `TalkWorker.status/0`, then start the laptop with:

```bash
export TALK_BOOTSTRAP_ENDPOINT_IDS=<Pi endpoint ID>
mix talk.ui
```

DNS/Pkarr and Mainline DHT resolve the Pi's current Iroh address from that ID.
This restores capability discovery, but remote Horde placement still requires a
directly reachable Partisan TCP endpoint.

## Stop

Stop the laptop dashboard with `Ctrl-C`. The Pi worker remains running and keeps
publishing until shutdown or firmware replacement.

## Troubleshooting

### No Pi appears

Confirm both devices use the same `IROH_FLEET_ID`, then check:

```elixir
ElixirRpc.TalkWorker.status()
```

### Discovery works but Horde handoff fails

Confirm the laptop can reach the displayed Pi Partisan IP and port. This is a
Partisan routing issue, not Iroh discovery.

### Firmware cannot find the daemon

Rebuild and then rebuild firmware:

```bash
./scripts/build_iroh_rpi4.sh
MIX_TARGET=rpi4 MIX_ENV=prod mix firmware
```

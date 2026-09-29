# Milestones

## 1. Local Proof

- Exchange signed capability records between two Iroh endpoints.
- Select a peer by typed constraints and load.
- Join the selected peer's signed LAN endpoint through Partisan.
- Place one uniquely identified child through Horde.
- Recover when the selected peer exits.

## 2. Physical Devices

- Deploy to 3-5 Nerves devices.
- Persist endpoint identity and sequence watermarks.
- Advertise GPU, VRAM, storage and battery metadata.
- Dispatch one VLM inference from a constrained node to a GPU node.

## 3. Difficult Networks

- Run the same demo across NAT using Iroh direct connections or relay fallback.
- Measure discovery, join and placement latency.
- Verify recovery after network partitions.

## 4. Scale

- Keep Partisan on bounded HyParView active and passive views as the fleet grows.
- Measure convergence, churn recovery, routing stretch and per-node resources.
- Add a DHT index only when fleet-wide Iroh gossip is a demonstrated limit.

Phase 1: Bare PoC

This phase removes hardware and networking variables to focus entirely on proving the core software thesis on a local, trusted network.

    Replace standard Erlang distribution with Partisan running in a simple full-mesh topology.

    Implement KademliaDHT with a single seed node on the local network for node discovery.

    Develop the Network.spawn/2 API to route workloads based on simulated node capabilities rather than physical hardware.

    Run the nodes locally on a single machine or across basic, homogeneous Linux VMs to prove the OTP fault tolerance and routing logic works.

Extension 1: Heterogeneous Physical Hardware

Once the software architecture is proven, introduce the physical Nerves devices and capability differences.

    Deploy Nerves firmware to a small testbed of 3–5 physical devices.

    Include a mix of standard nodes (Raspberry Pi 4) and at least one GPU-capable node.

    Have devices publish actual hardware capabilities (GPU VRAM, storage, battery level) to the DHT on boot.

    Execute the end-to-end demo where a constrained node successfully dispatches a Vision Language Model (VLM) inference task to the GPU node.

Extension 2: NAT Traversal and Complex Networking

With physical hardware collaborating on a LAN, introduce the complexities of real-world edge networks.

    Set up the Carrier-Grade NAT (CGNAT) simulator to isolate the devices.

    Implement AutoNAT probing to determine the NAT type upon device startup.

    Attempt Direct Connection Upgrade through Relay (DCUTR) simultaneous open for hole punching.

    Implement the circuit relay fallback mechanism through a mesh node with public reachability to ensure the system survives when hole punching fails.

Extension 3: Scale and Security (Stretch Goals for August)

If you clear the networking hurdles early, you can pull in features from your "Stage 2" production plan.

    Switch Partisan from a full-mesh topology to the HyParView gossip protocol to demonstrate O(logn) scaling capabilities.

    Upgrade the DHT bootstrap from a single node to a redundant seed cluster of 3 nodes.

    Implement security by requiring capability records to be signed with device keys, rejecting any unsigned records.

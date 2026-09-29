# Iroh Distribution Carrier v1

## Goal

Carry the Erlang distribution byte stream over authenticated Iroh QUIC without
changing Erlang terms or OTP semantics.

```text
ERTS distribution controller process
<-> framed local Port protocol
<-> Iroh daemon
<-> one QUIC bidirectional stream
<-> remote daemon/controller
```

The daemon never decodes Erlang distribution traffic.

## Iroh Protocol

ALPN:

```text
elixir-rpc/iroh-dist/1
```

The connecting endpoint opens one bidirectional stream and sends:

```text
magic       8 bytes  "ERLDIST1"
name_len    u16 big endian
from_node   UTF-8 bytes
target_len  u16 big endian
target_node UTF-8 bytes
```

The accepting daemon verifies that `target_node` is its registered local node,
binds a stream ID, and reports the incoming stream to the BEAM bridge. Everything
after this header is opaque Erlang distribution bytes.

Node names are limited to 255 UTF-8 bytes and must contain exactly one `@`.

## Local Port Protocol

Messages retain the existing packet-4 JSON envelope. Binary stream chunks are
hex encoded for v1; the bounded credit window prevents that convenience format
from becoming an unbounded memory path.

Commands:

```text
dist_listen(node_name)
dist_connect(from_node, target_node)
dist_send(stream_id, bytes)
dist_credit(stream_id, bytes)
dist_close(stream_id)
```

Events:

```text
dist_incoming(stream_id, from_node, target_node)
dist_connected(stream_id, target_node)
dist_data(stream_id, bytes)
dist_credit(stream_id, bytes)
dist_closed(stream_id, reason)
```

Each stream starts with 256 KiB outbound credit. `dist_send` fails rather than
queueing beyond available credit. Credit is replenished only after the QUIC
write completes. Frames and per-stream queues are bounded.

## Erlang Framing

During `dist_util` handshake, the controller adds and removes packet-2 framing:

```text
length:16/big, payload:length/binary
```

After handshake completion it carries packet-4 distribution frames:

```text
length:32/big, payload:length/binary
```

Partial headers, partial payloads, multiple packets per chunk, zero-length ticks,
and bytes arriving across the handshake boundary are preserved exactly.

## Identity

Capability discovery binds an Iroh EndpointId to one Erlang node name. Outgoing
setup resolves `target_node` through that verified registry. Incoming streams are
accepted only when the authenticated Iroh endpoint matches the registered
`from_node` binding.

## Four Hoare Contracts

```text
P: target node resolves to an authorized EndpointId
C: dist_connect(from, target)
Q: exactly one authenticated ordered QUIC stream is assigned a unique stream ID
```

```text
P: stream has n bytes of send credit and payload size <= n
C: dist_send(stream, payload)
Q: payload is written once, in order, and replacement credit arrives only after write completion
```

```text
P: controller buffer contains any fragmentation of valid packet-2 or packet-4 frames
C: feed(chunk)
Q: emitted payloads are byte-identical, ordered, complete, and residue remains buffered
```

```text
P: QUIC stream, daemon Port, or controller terminates
C: propagate_close(connection)
Q: the local controller terminates, net_kernel emits nodedown, and no stream state remains
```

## Non-Goals

- Reimplementing the Erlang handshake
- Decoding distribution terms
- Sharing one Iroh stream between node connections
- Hiding failed streams from `net_kernel`
- Supporting OTP versions other than 28 in v1

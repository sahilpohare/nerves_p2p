# Capability Discovery Protocol v1

## Purpose

Capability Discovery Protocol (CDP) lets an authorized Iroh endpoint announce
what work it can perform before Partisan membership exists. Discovery chooses a
peer; Partisan joins its signed LAN endpoint; Horde only manages processes after
the selected BEAM node joins.

CDP does not transport Erlang terms, execute remote functions, or manage Horde
membership.

## Transport

The first carrier is an `iroh-gossip` fleet topic. CDP messages are independent
of gossip and may later be indexed by a DHT without changing their signed form.
The gossip implementation must set `max_message_size` to at least 16 KiB; CDP
rejects larger messages before decoding.

The topic ID is:

```text
BLAKE3("elixir-rpc/capabilities/v1" || fleet_id)
```

Joining requires at least one provisioned bootstrap endpoint. LAN bootstrap may
use mDNS; remote bootstrap uses an Iroh endpoint ticket, address lookup, or
rendezvous service.

## Identity And Authorization

- `endpoint_id` is the 32-byte Iroh Ed25519 public key.
- Every device persists its Iroh secret key.
- Every receiver has a provisioned enrollment table of at most 1,024 endpoint
  IDs mapped to their one allowed BEAM node name.
- A valid Iroh signature authenticates an endpoint but does not authorize it.
- Receivers discard messages from endpoints outside the authorized fleet or
  whose announced node name differs from enrollment.
- `fleet_id` is a 32-byte deployment identifier and prevents cross-fleet replay.
- Revocation removes the active record immediately but retains its sequence
  watermark. Reauthorization continues from that watermark; resetting sequence
  requires enrollment of a new endpoint identity.

## Encoding

Messages use deterministic CBOR as defined by RFC 8949 section 4.2. Duplicate
map keys, indefinite-length items, non-shortest integers, unknown fields, and
map keys outside deterministic order are invalid. The signed bytes are:

```text
"elixir-rpc/cdp/v1\0" || body_bytes
```

The envelope is:

```text
{
  "body": bytes(deterministic_cbor(Announcement | Withdrawal)),
  "signature": bytes(64)
}
```

The receiver verifies strict Ed25519 using the `endpoint_id` decoded from
`body_bytes`, and verifies that decode followed by deterministic re-encoding is
byte-for-byte identical before accepting the message. A future protocol version
uses a new domain separator and message version.

## Announcement

```text
{
  "version": 1,
  "kind": "announcement",
  "fleet_id": bytes(32),
  "endpoint_id": bytes(32),
  "node_name": text,
  "partisan_ip": bytes(4),
  "partisan_port": uint,
  "sequence": uint,
  "ttl_ms": uint,
  "capabilities": {
    text: bool | uint | text | [text]
  },
  "load": {
    "running": uint,
    "capacity": uint
  }
}
```

Rules:

- `node_name` matches `[A-Za-z0-9_-]{1,64}@[A-Za-z0-9.-]{1,189}` and equals the
  name provisioned for `endpoint_id`.
- `partisan_ip` is the four-byte LAN IPv4 address advertised by Partisan.
- `partisan_port` is 1..65,535.
- The first sequence is 1. Sequence is persisted and strictly increases for an
  endpoint identity. A sender durably reserves and fsyncs the next sequence
  before signing or broadcasting it.
- `ttl_ms` is 5,000..60,000.
- `capabilities` has at most 32 entries.
- Capability names are 1..64 lowercase ASCII bytes matching
  `[a-z][a-z0-9_.-]*`.
- Text values are at most 256 bytes.
- Lists have at most 32 unique text values.
- `capacity` is 1..65,535 and `running <= capacity`.
- The encoded envelope is at most 16 KiB.
- A receiver processes at most 10 messages per second per authorized endpoint;
  excess messages are dropped before signature verification.

Receivers timestamp accepted announcements using their local monotonic clock.
An entry expires when:

```text
received_at_monotonic + ttl_ms <= now_monotonic
```

Wall-clock synchronization is not required. Senders republish every `ttl_ms / 3`.

## Withdrawal

```text
{
  "version": 1,
  "kind": "withdrawal",
  "fleet_id": bytes(32),
  "endpoint_id": bytes(32),
  "sequence": uint
}
```

A valid withdrawal removes the endpoint immediately and advances its sequence
watermark. A delayed announcement with a lower or equal sequence cannot restore
the entry.

## Receiver State

Each endpoint ID has:

```text
watermark: highest accepted sequence
record: optional active announcement
received_at: local monotonic timestamp
```

The watermark must survive process and device restarts. Losing or rolling back
the sequence store requires enrolling a new endpoint identity; silently
resetting a watermark or sender sequence is forbidden.

State transitions:

```text
absent  --valid announcement--> active
active  --newer announcement--> active
active  --valid withdrawal----> absent
active  --TTL expiry-----------> absent
any     --invalid/stale--------> unchanged
```

## Discovery Query

Queries are local and are not broadcast. `find` returns an ordered list.
Supported predicates are:

```text
equals(name, bool | uint | text)
at_least(name, uint)
contains(name, text)
```

`contains` means exact membership in a list of text values, never substring
matching. A missing capability or operand/value type mismatch does not match.
A peer matches only when every predicate matches. Expired, revoked, and fully
loaded peers never match. Results are ordered by:

1. Lowest `running / capacity`, compared without floating point.
2. Highest spare capacity.
3. Lexicographically smallest endpoint ID.

The deterministic order lets independent callers make the same decision from
the same registry state.

## Horde Handoff

Discovery returns this opaque result:

```text
{
  endpoint_id: bytes(32),
  node_name: text,
  partisan_ip: bytes(4),
  partisan_port: uint,
  sequence: uint,
  capabilities: map
}
```

The caller then:

1. Calls Partisan join with the signed node name, IPv4 address and port.
2. Resolves `node_name` only through the bounded enrollment table. Arbitrary
   network strings are never converted to atoms.
3. Waits for `:nodeup` and Horde membership.
4. Adds `meta: %{cdp_target_node: node}` to a uniquely identified child spec.
5. Submits it to Horde using `CDPDistributionStrategy`, which only returns the
   alive Horde member whose node equals `cdp_target_node`.

An endpoint disappearing between discovery and handoff is a normal
`peer_unavailable` result. Membership wait is bounded to five seconds. Retrying
the next candidate reuses the same child ID so Horde cannot start duplicates.

## Four Hoare Triples

### 1. Authentic Publication

```text
P: signature is valid, endpoint is authorized, fleet matches, fields are valid,
   and sequence > stored watermark
C: receive(announcement, now)
Q: watermark = sequence and the announcement is active until now + ttl_ms
```

### 2. Tamper And Impersonation Rejection

```text
P: signature is invalid, signer differs from endpoint_id, fleet differs, or a
   signed field was modified
C: receive(envelope, now)
Q: receiver state is unchanged and the message is rejected
```

### 3. Replay Rejection

```text
P: stored watermark = n and message sequence <= n
C: receive(validly_signed_message, now)
Q: receiver state is unchanged and the message is rejected as stale
```

### 4. Capability Selection

```text
P: registry contains authorized records with mixed capabilities, load, and age
C: find(requirements, now)
Q: result contains exactly fresh, non-full records satisfying every predicate,
   ordered by load, spare capacity, then endpoint ID
```

## Required Errors

```text
malformed
unsupported_version
message_too_large
wrong_fleet
unauthorized_endpoint
invalid_signature
invalid_record
stale_sequence
no_matching_peer
peer_unavailable
```

Errors are local API values. They are not reflected to gossip senders.

## Explicit Non-Goals

- Arbitrary MFA or ETF transport
- Global consensus about load
- Delivery guarantees beyond periodic republishing
- Byzantine resistance among authorized devices
- Horde membership before a capability match
- Internet traversal for Partisan, which is outside the talk-scope LAN demo

# Product Specification

## Goal

A Nerves device discovers peers by signed hardware capability and asks Horde to
place a worker on the selected Partisan member.

## Required Demo

1. Two Iroh endpoints join one fleet topic.
2. A worker publishes GPU capability, load, and its Partisan LAN endpoint.
3. A caller selects it with typed constraints.
4. Partisan joins the signed endpoint.
5. Horde starts one uniquely identified worker on the selected member.
6. The caller receives a visible result.

## Ownership

- Iroh: pre-membership discovery and signed capability records.
- Partisan: BEAM membership and messaging.
- Horde: distributed registry, placement, and supervision.

## Success

- No manual IP or node selection by application code.
- Expired, replayed, tampered, unauthorized, full, and nonmatching records are
  rejected.
- Discovery and placement failures return bounded errors instead of hanging.
- The complete demo runs from one documented command.

See `ARCHITECTURE.md` and `IROH_CAPABILITY_PROTOCOL.md` for normative details.

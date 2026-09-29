# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Delegated: server-rendered static HTML/CSS/JavaScript from the existing Elixir application, using a small Plug/Bandit endpoint and no frontend build chain.

## Users

The primary user is a technical speaker demonstrating the system live to an audience of Elixir and distributed-systems developers.

## Product Purpose

Elixir RPC demonstrates capability-based process placement for edge devices. Success means the audience can see a signed GPU capability travel over Iroh, become a selected Partisan peer, and produce a Horde-managed worker result.

## Positioning

Discovery happens by verified hardware capability before cluster membership; Partisan and Horde take over only after a peer is selected.

## Operating Context

The interface is projected during a live technical talk. It must remain legible at distance, recover cleanly from an empty or failed demo, and avoid requiring presenter interaction during the main sequence.

## Capabilities and Constraints

- Iroh provides signed capability gossip between real daemon processes.
- Partisan provides BEAM membership and messaging.
- Horde provides registry, placement, and supervision.
- The current talk demo labels Horde placement as local rather than claiming remote execution.
- The legacy libp2p runtime is excluded from the talk path.

## Evidence on Hand

- `mix talk.demo` is a runnable staged demonstration.
- `IROH_CAPABILITY_PROTOCOL.md` defines the signed discovery protocol.
- The repository has passing Elixir and Rust integration tests.
- No production fleet metrics, customer claims, or benchmark claims should be invented.

## Product Principles

- Show the real mechanism, not a simulated network diagram.
- Label local and remote behavior honestly.
- Keep one obvious narrative from discovery to placement.
- Prefer a deterministic talk demo over production configuration breadth.

## Accessibility & Inclusion

The dashboard must use high contrast, large readable type, non-color status labels, keyboard-safe controls, and reduced-motion support.

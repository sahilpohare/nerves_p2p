#!/bin/sh
# Launch one ElixirRpc node + TUI. Run this in multiple terminals to get
# multiple nodes. They will auto-discover each other via mDNS.
#
# Usage:
#   ./tui.sh              # random port
#   PARTISAN_PORT=10201 ./tui.sh

NODE_ID=$(openssl rand -hex 8)

# Pick a random unprivileged port if not set
if [ -z "$PARTISAN_PORT" ]; then
  PARTISAN_PORT=$(( ( RANDOM % 10000 ) + 20000 ))
fi

export PARTISAN_PORT
export MIX_TARGET=host

exec elixir \
  --name "${NODE_ID}@127.0.0.1" \
  --cookie elixir_rpc \
  -S mix tui

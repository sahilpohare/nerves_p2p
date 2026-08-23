#!/bin/sh
NODE_ID=$(openssl rand -hex 32)
exec iex --name "${NODE_ID}@127.0.0.1" --cookie elixir_rpc -S mix

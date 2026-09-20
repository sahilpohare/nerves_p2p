# Library Examples

After configuring the application with `ELIXIR_RPC_NETWORK_MODE=iroh`, use the
public library API to inspect signed capability records or place a child on an
authorized capable node:

```bash
mix run examples/capabilities.exs
mix run examples/start_child.exs
```

The placement example uses a provisioned string-to-existing-atom authorization
map; discovered node names are never converted into atoms.

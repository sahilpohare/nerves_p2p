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

Application code can publish and place work with the pitch-level API:

```elixir
{:ok, _record} = ElixirRpc.Network.advertise(gpu: 128, storage: 512)
{:ok, _pid} = ElixirRpc.Network.spawn([gpu: true], fn -> infer(frame) end)
```

Partisan uses HyParView with a six-peer active view and a thirty-peer passive
view, so adding fleet members does not create a full mesh.

# Nerves firmware (reference)

Files from the pre-library project layout: `mix.exs.reference`, `config.exs`,
`target.exs`, `runtime.exs`, `rel/`, `rootfs_overlay/`, `build_iroh_rpi4.sh`.
Copy them into a fresh Nerves project that depends on `:elixir_rpc` and set
`config :elixir_rpc, network_mode: :iroh`. Not built or tested here.

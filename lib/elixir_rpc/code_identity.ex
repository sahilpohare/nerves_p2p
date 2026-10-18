defmodule ElixirRpc.CodeIdentity do
  @moduledoc """
  Code identity for placement. Each peer advertises `"code" => ["Mod:md5", ...]`
  inside its signed capability record, so the hash is covered by the peer's
  Iroh signature. Placement requires the peer to advertise the same compiled-code
  hash we hold locally, so work only lands where the exact code already exists.
  """

  # ponytail: CDP caps a text list at 32 entries; switch to a single manifest hash if more modules must be placeable.
  @default_modules [ElixirRpc.DemoWorker]

  @doc "`\"Module:md5hex\"` for the locally loaded module (BEAM's own code hash)."
  @spec entry(module()) :: String.t()
  def entry(module) do
    "#{inspect(module)}:#{Base.encode16(module.module_info(:md5), case: :lower)}"
  end

  @doc "Entries this node advertises under the `code` capability."
  @spec advertised() :: [String.t()]
  def advertised do
    :elixir_rpc
    |> Application.get_env(:placeable_modules, @default_modules)
    |> Enum.map(&entry/1)
  end

  @doc "Requirement matching only peers holding the same code for `module`."
  @spec requirement(module()) :: {:code, {:contains, String.t()}}
  def requirement(module), do: {:code, {:contains, entry(module)}}
end

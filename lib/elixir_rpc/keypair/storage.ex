defmodule ElixirRpc.Keypair.Storage do
  @moduledoc """
  Behaviour for keypair persistence backends.

  The default production implementation is `ElixirRpc.Keypair.Storage.File`,
  which writes the protobuf-encoded keypair to disk with `0o600` permissions.

  `write/2` MUST be atomic with respect to concurrent readers.
  """

  @callback read(path :: Path.t()) :: {:ok, binary()} | {:error, atom()}
  @callback write(path :: Path.t(), bytes :: binary()) :: :ok | {:error, atom()}
end

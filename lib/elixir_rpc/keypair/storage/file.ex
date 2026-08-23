defmodule ElixirRpc.Keypair.Storage.File do
  @moduledoc """
  POSIX file implementation of `ElixirRpc.Keypair.Storage`.

  Uses atomic-write idiom (write to `<path>.tmp`, `chmod 0o600`, `rename`)
  so concurrent readers never observe a partial file. Keypair files MUST be
  `0o600` on Unix.
  """

  @behaviour ElixirRpc.Keypair.Storage

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def write(path, bytes) when is_binary(bytes) do
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, bytes),
         :ok <- File.chmod(tmp_path, 0o600),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, reason}
    end
  end
end

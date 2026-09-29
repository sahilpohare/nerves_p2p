defmodule ElixirRpc.Keypair do
  @moduledoc """
  Ed25519 keypair management for libp2p node identity.

  A node's identity is derived from its keypair. Persisting the keypair
  ensures a stable `PeerId` across restarts.

  ## Usage

      {:ok, keypair} = ElixirRpc.Keypair.generate()
      :ok = ElixirRpc.Keypair.save!(keypair, "identity.key")
      {:ok, keypair} = ElixirRpc.Keypair.load("identity.key")
      {:ok, node} = ElixirRpc.P2P.Node.start_link(keypair: keypair)

  """

  @enforce_keys [:public_key, :peer_id]
  defstruct [:public_key, :peer_id, :protobuf_bytes]

  @type t :: %__MODULE__{
          public_key: binary(),
          peer_id: String.t(),
          protobuf_bytes: binary() | nil
        }

  @spec generate() :: {:ok, t()} | {:error, term()}
  def generate do
    case native_module().generate_keypair() do
      {:ok, public_key, peer_id, protobuf_bytes} ->
        {:ok,
         %__MODULE__{public_key: public_key, peer_id: peer_id, protobuf_bytes: protobuf_bytes}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_protobuf(t()) :: {:ok, binary()} | {:error, term()}
  def to_protobuf(%__MODULE__{protobuf_bytes: bytes}) when is_binary(bytes), do: {:ok, bytes}
  def to_protobuf(%__MODULE__{}), do: {:error, :no_protobuf_data}
  def to_protobuf(_), do: {:error, :invalid_input}

  @spec from_protobuf(binary()) :: {:ok, t()} | {:error, :invalid_keypair}
  def from_protobuf(bytes) when is_binary(bytes) do
    case native_module().keypair_from_protobuf(bytes) do
      {:ok, public_key, peer_id} ->
        {:ok, %__MODULE__{public_key: public_key, peer_id: peer_id, protobuf_bytes: bytes}}

      {:error, _} ->
        {:error, :invalid_keypair}
    end
  end

  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{protobuf_bytes: bytes}, path) when is_binary(bytes) do
    ElixirRpc.Config.keypair_storage().write(path, bytes)
  end

  @spec save!(t(), Path.t()) :: :ok
  def save!(%__MODULE__{} = keypair, path) do
    case save(keypair, path) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to save keypair to #{path}: #{inspect(reason)}"
    end
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, :file_not_found | :invalid_keypair}
  def load(path) do
    case ElixirRpc.Config.keypair_storage().read(path) do
      {:ok, bytes} -> from_protobuf(bytes)
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load!(Path.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, keypair} ->
        keypair

      {:error, :file_not_found} ->
        raise File.Error, reason: :enoent, action: "read file", path: path

      {:error, reason} ->
        raise ArgumentError, "invalid keypair file: #{inspect(reason)}"
    end
  end

  defp native_module, do: ElixirRpc.Config.default_native_module()
end

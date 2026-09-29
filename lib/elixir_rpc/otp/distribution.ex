defmodule ElixirRpc.OTP.Distribution do
  @moduledoc """
  Transparent OTP message passing over libp2p.

  Provides `call/5`, `cast/4`, and `send/4` for communicating with
  GenServers on remote peers, using the same patterns as distributed Erlang
  but over libp2p's encrypted transport (Noise XX / X25519 + ChaChaPoly).

  ## Addressing

  Remote processes are addressed by `{registered_name, peer_id}`:

      peer = ElixirRpc.PeerId.new!("12D3KooW...")

      {:ok, result} = ElixirRpc.OTP.Distribution.call(node, peer, :my_server, :ping)
      :ok = ElixirRpc.OTP.Distribution.cast(node, peer, :my_server, {:update, data})
      :ok = ElixirRpc.OTP.Distribution.send(node, peer, :my_server, {:info, msg})

  ## Wire Format

  Messages are serialized with `:erlang.term_to_binary/2` using compressed
  format, and deserialized with `:erlang.binary_to_term/2` using `:safe`
  (rejects unknown atoms, prevents atom table exhaustion from untrusted peers).

  ## Handling Incoming Calls

  Start `ElixirRpc.OTP.Distribution.Server` in your supervision tree to
  serve remote calls.
  """

  alias ElixirRpc.{PeerId, RequestResponse}
  alias ElixirRpc.OTP.Distribution.Server

  @call_timeout 5_000

  @spec call(GenServer.server(), PeerId.t(), atom(), term(), non_neg_integer()) ::
          {:ok, term()} | {:error, :timeout | :unreachable | :noproc | :request_failed}
  def call(node, %PeerId{} = peer, name, message, timeout \\ @call_timeout)
      when is_atom(name) do
    payload = encode({:call, name, message})

    case Server.call(node, peer, payload, timeout) do
      {:ok, response_data} ->
        case decode(response_data) do
          {:ok, {:reply, reply}} -> {:ok, reply}
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, _} -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cast(GenServer.server(), PeerId.t(), atom(), term()) :: :ok
  def cast(node, %PeerId{} = peer, name, message) when is_atom(name) do
    payload = encode({:cast, name, message})
    RequestResponse.send_request(node, peer, payload)
    :ok
  end

  @spec send(GenServer.server(), PeerId.t(), atom(), term()) :: :ok
  def send(node, %PeerId{} = peer, name, message) when is_atom(name) do
    payload = encode({:send, name, message})
    RequestResponse.send_request(node, peer, payload)
    :ok
  end

  @spec handle_remote_request(tuple()) :: {:ok, binary()}
  def handle_remote_request({:call, name, message}) do
    case whereis(name) do
      nil ->
        {:ok, encode({:error, :noproc})}

      pid ->
        response =
          case safe_call(pid, message) do
            {:ok, reply} -> encode({:reply, reply})
            {:error, reason} -> encode({:error, reason})
          end

        {:ok, response}
    end
  end

  def handle_remote_request({:cast, name, message}) do
    case whereis(name) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end

    {:ok, encode({:reply, :ok})}
  end

  def handle_remote_request({:send, name, message}) do
    case whereis(name) do
      nil -> :ok
      pid -> Kernel.send(pid, message)
    end

    {:ok, encode({:reply, :ok})}
  end

  def handle_remote_request(_), do: {:ok, encode({:error, :unknown_request})}

  @spec encode(term()) :: binary()
  def encode(term) do
    :erlang.term_to_binary(term, [:compressed])
  end

  @max_payload_bytes 1_048_576

  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_message | :payload_too_large}
  def decode(binary) when is_binary(binary) and byte_size(binary) > @max_payload_bytes do
    {:error, :payload_too_large}
  end

  def decode(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_message}
  end

  def decode(_), do: {:error, :invalid_input}

  defp whereis(name) when is_atom(name), do: Process.whereis(name)
  defp whereis({:via, registry, key}), do: GenServer.whereis({:via, registry, key})

  defp safe_call(pid, message) do
    {:ok, GenServer.call(pid, message, @call_timeout)}
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, inspect(reason)}}
  end
end

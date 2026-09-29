defmodule ElixirRpc.CapabilityRPC do
  @moduledoc """
  Capability-based RPC routing.

  Routes calls to the best peer that advertises the required capability,
  rather than addressing a specific node name.

  ## Addressing

      # Traditional — specific node
      :rpc.call(:node1@host, Camera, :capture, [])

      # Capability-based — any peer with :camera capability
      ElixirRpc.CapabilityRPC.call({:capability, :camera}, Camera, :capture, [])

      # Capability + constraints
      ElixirRpc.CapabilityRPC.call(
        {:capability, :camera, %{min_resolution: "720p", location: "zone_a"}},
        Camera, :capture, []
      )

      # Load-balanced across all capable peers
      ElixirRpc.CapabilityRPC.call({:capability, :processing, :load_balanced}, Task, :process, [data])

  ## How It Works

  1. Query `ElixirRpc.Discovery` for peers with the required capability.
  2. Select the best peer using the given strategy (first match, load-balanced, etc.).
  3. Dispatch via `ElixirRpc.OTP.Distribution.call/5` over libp2p.

  For Partisan-connected peers, you may also use standard `:rpc.call/4` once the
  peer is in the Partisan mesh — see `ElixirRpc.PeerManager`.
  """

  require Logger

  alias ElixirRpc.{Discovery, OTP.Distribution, PeerId}

  @default_timeout 10_000

  @type target ::
          {:capability, atom()}
          | {:capability, atom(), map() | :load_balanced}

  @doc """
  Synchronous call to a peer selected by capability.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec call(target(), module(), atom(), list(), non_neg_integer()) ::
          {:ok, term()} | {:error, :no_capable_peer | :timeout | :unreachable | term()}
  def call(target, module, function, args, timeout \\ @default_timeout) do
    with {:ok, peer} <- select_peer(target) do
      message = {:apply, module, function, args}
      Distribution.call(ElixirRpc.Node, peer, :__capability_rpc_server__, message, timeout)
    end
  end

  @doc """
  Fire-and-forget cast to a peer selected by capability.
  """
  @spec cast(target(), module(), atom(), list()) :: :ok | {:error, :no_capable_peer}
  def cast(target, module, function, args) do
    with {:ok, peer} <- select_peer(target) do
      message = {:apply, module, function, args}
      Distribution.cast(ElixirRpc.Node, peer, :__capability_rpc_server__, message)
    end
  end

  @doc """
  Returns all peers currently known to have the given capability.
  """
  @spec peers_with(atom()) :: [PeerId.t()]
  def peers_with(capability) do
    case Discovery.find_capability(capability) do
      {:ok, peer_infos} ->
        peer_infos
        |> Enum.reject(&is_nil(&1.peer_id))
        |> Enum.map(fn info -> PeerId.new!(info.peer_id) end)

      _ ->
        []
    end
  end

  ## Private

  defp select_peer({:capability, cap}), do: pick_first(cap, %{})
  defp select_peer({:capability, cap, :load_balanced}), do: pick_load_balanced(cap)

  defp select_peer({:capability, cap, constraints}) when is_map(constraints),
    do: pick_first(cap, constraints)

  defp pick_first(capability, constraints) do
    case Discovery.find_capability(capability) do
      {:ok, [_ | _] = peers} ->
        peers
        |> filter_constraints(constraints)
        |> case do
          [] -> {:error, :no_capable_peer}
          [peer | _] -> peer_id_from_info(peer)
        end

      {:ok, []} ->
        {:error, :no_capable_peer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pick_load_balanced(capability) do
    case Discovery.find_capability(capability) do
      {:ok, [_ | _] = peers} ->
        # Simple round-robin using erlang timestamp as entropy
        idx = :erlang.phash2(:os.timestamp(), length(peers))
        peer = Enum.at(peers, idx)
        peer_id_from_info(peer)

      {:ok, []} ->
        {:error, :no_capable_peer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp filter_constraints(peers, constraints) when map_size(constraints) == 0, do: peers

  defp filter_constraints(peers, constraints) do
    Enum.filter(peers, fn peer ->
      Enum.all?(constraints, fn {k, v} ->
        Map.get(peer.metadata, k) == v or Map.get(peer.metadata, to_string(k)) == v
      end)
    end)
  end

  defp peer_id_from_info(%{peer_id: id}) when is_binary(id) do
    PeerId.new(id)
  end

  defp peer_id_from_info(_), do: {:error, :no_capable_peer}
end

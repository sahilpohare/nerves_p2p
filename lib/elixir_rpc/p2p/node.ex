defmodule ElixirRpc.P2P.Node do
  @moduledoc """
  GenServer wrapping a libp2p node.

  Manages the lifecycle of a libp2p node, dispatches network events through
  `ElixirRpc.P2P.Node.HandlerRegistry`, and provides the client API for
  all node operations.

  ## Starting

      {:ok, node} = ElixirRpc.P2P.Node.start_link(
        listen_addrs: ["/ip4/0.0.0.0/tcp/0"],
        gossipsub_topics: ["my-topic"],
        enable_mdns: true
      )

  ## Events

  Register to receive specific event types:

      ElixirRpc.P2P.Node.register_handler(node, :peer_discovered)
      # Receive: {:libp2p, :peer_discovered, %Event.PeerDiscovered{}}

  Event types: `:connection_established`, `:connection_closed`, `:new_listen_addr`,
  `:gossipsub_message`, `:peer_discovered`, `:dht_query_result`, `:inbound_request`,
  `:outbound_response`, `:dial_failure`, `:nat_status_changed`, `:relay_reservation_accepted`,
  `:hole_punch_outcome`, `:external_addr_confirmed`.
  """

  use GenServer
  require Logger

  alias ElixirRpc.PeerId
  alias ElixirRpc.P2P.Node.{Config, Event, HandlerRegistry, NetworkOps, NifOps, Result}
  alias ElixirRpc.Multiaddr

  import ElixirRpc.Call, only: [safe_call: 2]

  @default_native Application.compile_env(:elixir_rpc, :native_module, ElixirRpc.P2P.Native.Nif)

  defstruct [:handle, :peer_id, :native, :dht_state_path, :dht_storage]

  @type t :: %__MODULE__{
          handle: reference() | nil,
          peer_id: PeerId.t() | nil,
          native: module(),
          dht_state_path: String.t() | nil,
          dht_storage: module() | nil
        }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, node_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, node_opts, gen_opts)
  end

  @doc "Starts a node under `ElixirRpc.P2P.NodeSupervisor` for automatic restart."
  @spec start_supervised(keyword()) :: DynamicSupervisor.on_start_child()
  def start_supervised(opts \\ []) do
    DynamicSupervisor.start_child(ElixirRpc.P2P.NodeSupervisor, {__MODULE__, opts})
  end

  @spec peer_id(GenServer.server()) :: {:ok, PeerId.t()} | {:error, term()}
  def peer_id(node), do: safe_call(node, :peer_id)

  @spec connected_peers(GenServer.server()) :: {:ok, [PeerId.t()]} | {:error, term()}
  def connected_peers(node), do: safe_call(node, :connected_peers)

  @spec listening_addrs(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def listening_addrs(node), do: safe_call(node, :listening_addrs)

  @spec dial(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def dial(node, addr) when is_binary(addr) do
    :telemetry.span([:elixir_rpc, :node, :dial], %{addr: addr}, fn ->
      result =
        case Multiaddr.new(addr) do
          {:ok, _} -> safe_call(node, {:dial, addr})
          {:error, _} -> {:error, :invalid_multiaddr}
        end

      {result, %{result: Result.tag(result)}}
    end)
  end

  @spec publish(GenServer.server(), String.t(), binary()) :: :ok | {:error, term()}
  def publish(node, topic, data), do: safe_call(node, {:publish, topic, data})

  @spec subscribe(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def subscribe(node, topic), do: safe_call(node, {:subscribe, topic})

  @spec unsubscribe(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(node, topic), do: safe_call(node, {:unsubscribe, topic})

  @spec send_request(GenServer.server(), PeerId.t(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def send_request(node, peer_id, data) do
    safe_call(node, {:rpc_send_request, PeerId.to_string(peer_id), data})
  end

  @spec send_response(GenServer.server(), String.t(), binary()) :: :ok | {:error, term()}
  def send_response(node, channel_id, data) do
    safe_call(node, {:rpc_send_response, channel_id, data})
  end

  @spec dht_bootstrap(GenServer.server()) :: :ok | {:error, term()}
  def dht_bootstrap(node), do: safe_call(node, :dht_bootstrap)

  @spec dht_put(GenServer.server(), binary(), binary()) :: :ok | {:error, term()}
  def dht_put(node, key, value), do: safe_call(node, {:dht_put, key, value})

  @spec dht_get(GenServer.server(), binary()) :: :ok | {:error, term()}
  def dht_get(node, key), do: safe_call(node, {:dht_get, key})

  @spec dht_find_peer(GenServer.server(), PeerId.t()) :: :ok | {:error, term()}
  def dht_find_peer(node, peer_id) do
    safe_call(node, {:dht_find_peer, PeerId.to_string(peer_id)})
  end

  @spec register_handler(GenServer.server(), atom(), pid()) :: :ok | {:error, term()}
  def register_handler(node, event_type, pid \\ self()) do
    case GenServer.whereis(node) do
      nil -> {:error, :no_node}
      node_pid -> HandlerRegistry.register(HandlerRegistry, node_pid, event_type, pid)
    end
  end

  @spec unregister_handler(GenServer.server(), atom(), pid()) :: :ok | {:error, term()}
  def unregister_handler(node, event_type, pid \\ self()) do
    case GenServer.whereis(node) do
      nil -> {:error, :no_node}
      node_pid -> HandlerRegistry.unregister(HandlerRegistry, node_pid, event_type, pid)
    end
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(node), do: GenServer.stop(node)

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    native = Keyword.get(opts, :native_module, @default_native)
    config_opts = Keyword.drop(opts, [:native_module])
    config = Config.new(config_opts)

    with {:ok, valid_config} <- Config.validate(config),
         config_map = Config.to_nif_map(valid_config),
         handle when is_reference(handle) <- start_node_safe(native, config_map),
         peer_id_str = native.get_peer_id(handle),
         {:ok, peer_id} <- PeerId.new(peer_id_str) do
      native.register_event_handler(handle, self())

      dht_state_path = valid_config.discovery.dht_state_path
      dht_storage = ElixirRpc.Config.dht_state_storage()
      maybe_import_dht_state(native, handle, dht_state_path, dht_storage)

      Logger.info("[ElixirRpc.P2P.Node] started: #{peer_id_str}")

      {:ok,
       %__MODULE__{
         handle: handle,
         peer_id: peer_id,
         native: native,
         dht_state_path: dht_state_path,
         dht_storage: dht_storage
       }}
    else
      {:error, reason} -> {:stop, {:failed_to_start, reason}}
    end
  end

  @impl true
  def handle_call(call, from, state) do
    if NetworkOps.handles?(call) do
      NetworkOps.handle(call, from, state)
    else
      NifOps.handle(call, from, state)
    end
  end

  @impl true
  def handle_info({:libp2p_event, {:peers_discovered, peer_list}}, state)
      when is_list(peer_list) do
    Enum.each(peer_list, &dispatch_event/1)
    {:noreply, state}
  end

  def handle_info({:libp2p_event, raw_event}, state) do
    dispatch_event(raw_event)
    {:noreply, state}
  end

  def handle_info({:libp2p_noop}, state), do: {:noreply, state}
  def handle_info(:libp2p_noop, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.warning("[ElixirRpc.P2P.Node] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[ElixirRpc.P2P.Node] stopping (#{inspect(reason)}): #{state.peer_id}")
    HandlerRegistry.cleanup_node(HandlerRegistry, self())
    maybe_export_dht_state(state)
    state.native.stop_node(state.handle)
    :ok
  end

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    %{status | state: %{handle: :redacted, peer_id: state.peer_id, native: state.native}}
  end

  def format_status(status), do: status

  # --- Private ---

  defp start_node_safe(native, config_map) do
    native.start_node(config_map)
  rescue
    e in ErlangError -> {:error, e.original}
  catch
    :error, reason -> {:error, reason}
  end

  defp maybe_import_dht_state(_native, _handle, nil, _storage), do: :ok

  defp maybe_import_dht_state(native, handle, path, storage) do
    case storage.read(path) do
      {:ok, bytes} ->
        case native.kad_import_routing_table(handle, bytes) do
          {:ok, count} ->
            Logger.info("[ElixirRpc.P2P.Node] Imported #{count} DHT entries from #{path}")

          {:error, reason} ->
            Logger.warning(
              "[ElixirRpc.P2P.Node] DHT state import failed (#{inspect(reason)}); continuing with empty routing table"
            )
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[ElixirRpc.P2P.Node] Could not read DHT state from #{path} (#{inspect(reason)}); continuing"
        )
    end
  end

  defp maybe_export_dht_state(%__MODULE__{dht_state_path: nil}), do: :ok

  defp maybe_export_dht_state(%__MODULE__{
         native: native,
         handle: handle,
         dht_state_path: path,
         dht_storage: storage
       }) do
    case native.kad_export_routing_table(handle) do
      {:ok, bytes} ->
        case storage.write(path, bytes) do
          :ok ->
            Logger.debug("[ElixirRpc.P2P.Node] DHT state exported (#{byte_size(bytes)} bytes) → #{path}")

          {:error, reason} ->
            Logger.warning(
              "[ElixirRpc.P2P.Node] Could not write DHT state to #{path} (#{inspect(reason)}); shutdown continues"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "[ElixirRpc.P2P.Node] DHT state export failed (#{inspect(reason)}); shutdown continues"
        )
    end
  end

  defp dispatch_event(raw) do
    case Event.from_raw(raw) do
      {:ok, event} ->
        event_type = event_type_for(event)
        HandlerRegistry.dispatch(HandlerRegistry, self(), event_type, event)

      {:error, :unknown_event} ->
        Logger.debug("[ElixirRpc.P2P.Node] Unknown event: #{inspect(raw)}")
    end
  end

  defp event_type_for(%Event.ConnectionEstablished{}), do: :connection_established
  defp event_type_for(%Event.ConnectionClosed{}), do: :connection_closed
  defp event_type_for(%Event.NewListenAddr{}), do: :new_listen_addr
  defp event_type_for(%Event.GossipsubMessage{}), do: :gossipsub_message
  defp event_type_for(%Event.PeerDiscovered{}), do: :peer_discovered
  defp event_type_for(%Event.DHTQueryResult{}), do: :dht_query_result
  defp event_type_for(%Event.InboundRequest{}), do: :inbound_request
  defp event_type_for(%Event.OutboundResponse{}), do: :outbound_response
  defp event_type_for(%Event.DialFailure{}), do: :dial_failure
  defp event_type_for(%Event.NatStatusChanged{}), do: :nat_status_changed
  defp event_type_for(%Event.RelayReservationAccepted{}), do: :relay_reservation_accepted
  defp event_type_for(%Event.HolePunchOutcome{}), do: :hole_punch_outcome
  defp event_type_for(%Event.ExternalAddrConfirmed{}), do: :external_addr_confirmed
end

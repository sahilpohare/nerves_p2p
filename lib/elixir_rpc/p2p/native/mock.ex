defmodule ElixirRpc.P2P.Native.Mock do
  @moduledoc false

  @behaviour ElixirRpc.P2P.Native

  @mock_peer_id "12D3KooWDpJ7As7BWAwRMfu1VU2WCqNjvq387JEYKDBj4kx6nXTN"
  @mock_peer_id_2 "12D3KooWRPmBBCBTuGh1cnUuFVr35GYnm4bRXYsSB94TXJLAg4mA"

  # --- Core ---

  @impl ElixirRpc.P2P.Native
  def start_node(_config), do: make_ref()

  @impl ElixirRpc.P2P.Native
  def stop_node(_handle), do: :ok

  @impl ElixirRpc.P2P.Native
  def register_event_handler(_handle, _pid), do: :ok

  @impl ElixirRpc.P2P.Native
  def get_peer_id(_handle), do: @mock_peer_id

  @impl ElixirRpc.P2P.Native
  def connected_peers(_handle), do: []

  @impl ElixirRpc.P2P.Native
  def listening_addrs(_handle), do: ["/ip4/127.0.0.1/tcp/0"]

  @impl ElixirRpc.P2P.Native
  def dial(_handle, _addr), do: :ok

  # --- Pubsub ---

  @impl ElixirRpc.P2P.Native
  def publish(_handle, _topic, _data), do: :ok

  @impl ElixirRpc.P2P.Native
  def subscribe(_handle, _topic), do: :ok

  @impl ElixirRpc.P2P.Native
  def unsubscribe(_handle, _topic), do: :ok

  @impl ElixirRpc.P2P.Native
  def gossipsub_mesh_peers(_handle, _topic), do: {:ok, [@mock_peer_id_2]}

  @impl ElixirRpc.P2P.Native
  def gossipsub_all_peers(_handle), do: {:ok, [@mock_peer_id_2]}

  @impl ElixirRpc.P2P.Native
  def gossipsub_peer_score(_handle, _peer_id), do: {:ok, 0.0}

  # --- DHT ---

  @impl ElixirRpc.P2P.Native
  def dht_put(_handle, _key, _value), do: :ok

  @impl ElixirRpc.P2P.Native
  def dht_get(_handle, _key), do: :ok

  @impl ElixirRpc.P2P.Native
  def dht_find_peer(_handle, _peer_id), do: :ok

  @impl ElixirRpc.P2P.Native
  def dht_provide(_handle, _key), do: :ok

  @impl ElixirRpc.P2P.Native
  def dht_find_providers(_handle, _key), do: :ok

  @impl ElixirRpc.P2P.Native
  def dht_bootstrap(_handle), do: :ok

  @impl ElixirRpc.P2P.Native
  def kad_export_routing_table(_handle) do
    {:ok, Process.get(:mock_dht_state, <<"L2DT", 1, 0, 0, 0, 0>>)}
  end

  @impl ElixirRpc.P2P.Native
  def kad_import_routing_table(_handle, data) when is_binary(data) do
    Process.put(:mock_dht_state, data)
    {:ok, 0}
  end

  # --- RPC ---

  @impl ElixirRpc.P2P.Native
  def rpc_send_request(_handle, _peer_id, _data) do
    {:ok, "mock-req-#{System.unique_integer([:positive])}"}
  end

  @impl ElixirRpc.P2P.Native
  def rpc_send_response(_handle, _channel_id, _data), do: :ok

  # --- Relay ---

  @impl ElixirRpc.P2P.Native
  def listen_via_relay(_handle, _relay_addr), do: :ok

  # --- Metrics ---

  @impl ElixirRpc.P2P.Native
  def bandwidth_stats(_handle), do: {:ok, 0, 0}

  @impl ElixirRpc.P2P.Native
  def prometheus_metrics(_handle), do: {:ok, "# mock — no metrics registered\n"}

  # --- Rendezvous ---

  @impl ElixirRpc.P2P.Native
  def rendezvous_register(_handle, _namespace, _ttl, _rendezvous_peer), do: :ok

  @impl ElixirRpc.P2P.Native
  def rendezvous_discover(_handle, _namespace, _rendezvous_peer), do: :ok

  @impl ElixirRpc.P2P.Native
  def rendezvous_unregister(_handle, _namespace, _rendezvous_peer), do: :ok

  # --- Keypair ---

  @impl ElixirRpc.P2P.Native
  def generate_keypair do
    id = System.unique_integer([:positive])

    peer_id =
      "12D3KooW#{String.pad_leading("#{id}", 44, "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrs")}"

    {:ok, "mock-pubkey-#{id}", peer_id, "mock-proto:#{peer_id}"}
  end

  @impl ElixirRpc.P2P.Native
  def keypair_from_protobuf("mock-proto:" <> peer_id), do: {:ok, "mock-pubkey", peer_id}
  def keypair_from_protobuf(_), do: {:error, :invalid_keypair}
end

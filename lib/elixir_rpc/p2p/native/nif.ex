defmodule ElixirRpc.P2P.Native.Nif do
  @moduledoc false

  @behaviour ElixirRpc.P2P.Native

  use Rustler, otp_app: :elixir_rpc, crate: "p2p_bridge"

  # Fallback stubs — overwritten by Rustler when the NIF loads successfully.

  @impl ElixirRpc.P2P.Native
  def start_node(_config), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def stop_node(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def register_event_handler(_handle, _pid), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def get_peer_id(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def connected_peers(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def listening_addrs(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def dial(_handle, _addr), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def publish(_handle, _topic, _data), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def subscribe(_handle, _topic), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def unsubscribe(_handle, _topic), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def gossipsub_mesh_peers(_handle, _topic), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def gossipsub_all_peers(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def gossipsub_peer_score(_handle, _peer_id), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def dht_put(_handle, _key, _value), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def dht_get(_handle, _key), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def dht_find_peer(_handle, _peer_id), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def dht_provide(_handle, _key), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def dht_find_providers(_handle, _key), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def dht_bootstrap(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def kad_export_routing_table(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def kad_import_routing_table(_handle, _data), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def rpc_send_request(_handle, _peer_id, _data), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def rpc_send_response(_handle, _channel_id, _data), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def listen_via_relay(_handle, _relay_addr), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def bandwidth_stats(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def prometheus_metrics(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def rendezvous_register(_handle, _namespace, _ttl, _rendezvous_peer),
    do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def rendezvous_discover(_handle, _namespace, _rendezvous_peer),
    do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def rendezvous_unregister(_handle, _namespace, _rendezvous_peer),
    do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def generate_keypair, do: :erlang.nif_error(:nif_not_loaded)

  @impl ElixirRpc.P2P.Native
  def keypair_from_protobuf(_bytes), do: :erlang.nif_error(:nif_not_loaded)
end

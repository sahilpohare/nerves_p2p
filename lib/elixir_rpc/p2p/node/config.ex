defmodule ElixirRpc.P2P.Node.Config do
  @moduledoc """
  Configuration for a P2P node.

  Accepts a flat keyword list and routes each key into the appropriate subgroup.

  ## Examples

      iex> ElixirRpc.P2P.Node.Config.new().discovery.enable_mdns
      true

      iex> ElixirRpc.P2P.Node.Config.new(listen_addrs: ["/ip4/0.0.0.0/tcp/4001"]).network.listen_addrs
      ["/ip4/0.0.0.0/tcp/4001"]
  """

  defmodule Network do
    @moduledoc false
    defstruct listen_addrs: ["/ip4/0.0.0.0/tcp/0"],
              idle_connection_timeout_secs: 60,
              max_established_per_peer: 2,
              max_established_incoming: 256,
              max_established_outgoing: 256,
              max_pending_incoming: 256,
              max_pending_outgoing: 256,
              memory_max_percentage: nil

    @type t :: %__MODULE__{
            listen_addrs: [String.t()],
            idle_connection_timeout_secs: pos_integer(),
            max_established_per_peer: pos_integer(),
            max_established_incoming: pos_integer(),
            max_established_outgoing: pos_integer(),
            max_pending_incoming: pos_integer(),
            max_pending_outgoing: pos_integer(),
            memory_max_percentage: float() | nil
          }
  end

  defmodule Discovery do
    @moduledoc false
    defstruct enable_mdns: true,
              mdns_auto_dial: true,
              enable_kademlia: true,
              bootstrap_peers: [],
              dht_state_path: nil

    @type t :: %__MODULE__{
            enable_mdns: boolean(),
            mdns_auto_dial: boolean(),
            enable_kademlia: boolean(),
            bootstrap_peers: [String.t()],
            dht_state_path: String.t() | nil
          }
  end

  defmodule Gossipsub do
    @moduledoc false
    defstruct topics: [],
              mesh_n: 6,
              mesh_n_low: 4,
              mesh_n_high: 12,
              gossip_lazy: 6,
              max_transmit_size: 65536,
              heartbeat_interval_ms: 1000,
              peer_score_disabled: false,
              peer_score: nil,
              thresholds: nil

    @type t :: %__MODULE__{
            topics: [String.t()],
            mesh_n: pos_integer(),
            mesh_n_low: pos_integer(),
            mesh_n_high: pos_integer(),
            gossip_lazy: pos_integer(),
            max_transmit_size: pos_integer(),
            heartbeat_interval_ms: pos_integer(),
            peer_score_disabled: boolean(),
            peer_score: map() | nil,
            thresholds: map() | nil
          }
  end

  defmodule RequestResponse do
    @moduledoc false
    defstruct protocol_name: nil,
              request_timeout_secs: 30

    @type t :: %__MODULE__{
            protocol_name: String.t() | nil,
            request_timeout_secs: pos_integer()
          }
  end

  defmodule Relay do
    @moduledoc false
    defstruct enable_relay_client: false,
              enable_relay_server: false,
              relay_peers: [],
              relay_max_reservations: 128,
              relay_max_circuits: 16,
              relay_max_circuit_duration_secs: 120,
              relay_max_circuit_bytes: 131_072

    @type t :: %__MODULE__{
            enable_relay_client: boolean(),
            enable_relay_server: boolean(),
            relay_peers: [String.t()],
            relay_max_reservations: pos_integer(),
            relay_max_circuits: pos_integer(),
            relay_max_circuit_duration_secs: pos_integer(),
            relay_max_circuit_bytes: pos_integer()
          }
  end

  defmodule Rendezvous do
    @moduledoc false
    defstruct enable: false,
              namespace: nil,
              ttl: 7200,
              peers: []

    @type t :: %__MODULE__{
            enable: boolean(),
            namespace: String.t() | nil,
            ttl: pos_integer(),
            peers: [String.t()]
          }
  end

  defstruct network: nil,
            discovery: nil,
            gossipsub: nil,
            request_response: nil,
            relay: nil,
            rendezvous: nil,
            keypair_bytes: nil,
            enable_autonat: false,
            enable_autonat_server: false,
            enable_upnp: false,
            enable_websocket: false,
            enable_rendezvous_server: false

  @type t :: %__MODULE__{
          network: Network.t(),
          discovery: Discovery.t(),
          gossipsub: Gossipsub.t(),
          request_response: RequestResponse.t(),
          relay: Relay.t(),
          rendezvous: Rendezvous.t(),
          keypair_bytes: binary() | nil,
          enable_autonat: boolean(),
          enable_autonat_server: boolean(),
          enable_upnp: boolean(),
          enable_websocket: boolean(),
          enable_rendezvous_server: boolean()
        }

  @network_keys [
    :listen_addrs,
    :idle_connection_timeout_secs,
    :max_established_per_peer,
    :max_established_incoming,
    :max_established_outgoing,
    :max_pending_incoming,
    :max_pending_outgoing,
    :memory_max_percentage
  ]
  @discovery_keys [
    :enable_mdns,
    :mdns_auto_dial,
    :enable_kademlia,
    :bootstrap_peers,
    :dht_state_path
  ]
  @gossipsub_renames %{
    gossipsub_topics: :topics,
    gossipsub_mesh_n: :mesh_n,
    gossipsub_mesh_n_low: :mesh_n_low,
    gossipsub_mesh_n_high: :mesh_n_high,
    gossipsub_gossip_lazy: :gossip_lazy,
    gossipsub_max_transmit_size: :max_transmit_size,
    gossipsub_heartbeat_interval_ms: :heartbeat_interval_ms,
    gossipsub_peer_score_disabled: :peer_score_disabled,
    gossipsub_peer_score: :peer_score,
    gossipsub_thresholds: :thresholds
  }
  @rpc_renames %{
    rpc_protocol_name: :protocol_name,
    rpc_request_timeout_secs: :request_timeout_secs
  }
  @relay_keys [
    :enable_relay_client,
    :enable_relay_server,
    :relay_peers,
    :relay_max_reservations,
    :relay_max_circuits,
    :relay_max_circuit_duration_secs,
    :relay_max_circuit_bytes
  ]
  @rendezvous_keys [:enable_rendezvous, :rendezvous_namespace, :rendezvous_ttl, :rendezvous_peers]
  @protocol_keys [
    :enable_autonat,
    :enable_autonat_server,
    :enable_upnp,
    :enable_websocket,
    :enable_rendezvous_server
  ]
  @known_keys [:keypair_bytes] ++
                @network_keys ++
                @discovery_keys ++
                Map.keys(@gossipsub_renames) ++
                Map.keys(@rpc_renames) ++
                @relay_keys ++
                @rendezvous_keys ++
                @protocol_keys

  @spec new() :: t()
  def new do
    %__MODULE__{
      keypair_bytes: nil,
      network: %Network{},
      discovery: %Discovery{},
      gossipsub: %Gossipsub{},
      request_response: %RequestResponse{},
      relay: %Relay{},
      rendezvous: %Rendezvous{},
      enable_autonat: false,
      enable_autonat_server: false,
      enable_upnp: false,
      enable_websocket: false,
      enable_rendezvous_server: false
    }
  end

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    Keyword.validate!(opts, @known_keys)

    gossipsub_overrides = rename_keys(opts, @gossipsub_renames)
    rpc_overrides = rename_keys(opts, @rpc_renames)

    rendezvous_overrides =
      []
      |> put_if(opts[:enable_rendezvous], :enable)
      |> put_if(opts[:rendezvous_namespace], :namespace)
      |> put_if(opts[:rendezvous_ttl], :ttl)
      |> put_if(opts[:rendezvous_peers], :peers)

    %__MODULE__{
      keypair_bytes: opts[:keypair_bytes],
      network: struct(Network, Keyword.take(opts, @network_keys)),
      discovery: struct(Discovery, Keyword.take(opts, @discovery_keys)),
      gossipsub: struct(Gossipsub, gossipsub_overrides),
      request_response: struct(RequestResponse, rpc_overrides),
      relay: struct(Relay, Keyword.take(opts, @relay_keys)),
      rendezvous: struct(Rendezvous, rendezvous_overrides),
      enable_autonat: opts[:enable_autonat] || false,
      enable_autonat_server: opts[:enable_autonat_server] || false,
      enable_upnp: opts[:enable_upnp] || false,
      enable_websocket: opts[:enable_websocket] || false,
      enable_rendezvous_server: opts[:enable_rendezvous_server] || false
    }
  end

  defp rename_keys(opts, renames) do
    Enum.reduce(renames, [], fn {flat_key, field}, acc ->
      case Keyword.fetch(opts, flat_key) do
        {:ok, value} -> [{field, value} | acc]
        :error -> acc
      end
    end)
  end

  defp put_if(acc, nil, _key), do: acc
  defp put_if(acc, value, key), do: [{key, value} | acc]

  @spec validate(t()) :: {:ok, t()} | {:error, atom()}
  def validate(%__MODULE__{network: %Network{listen_addrs: []}}), do: {:error, :no_listen_addrs}

  def validate(%__MODULE__{network: %Network{idle_connection_timeout_secs: t}}) when t <= 0,
    do: {:error, :invalid_timeout}

  def validate(%__MODULE__{} = config), do: {:ok, config}
  def validate(_), do: {:error, :invalid_config}

  @doc "Converts config to the flat string-keyed map the NIF expects."
  @spec to_nif_map(t()) :: %{String.t() => term()}
  def to_nif_map(%__MODULE__{} = c) do
    %{
      "keypair_bytes" => c.keypair_bytes,
      # Network
      "listen_addrs" => c.network.listen_addrs,
      "idle_connection_timeout_secs" => c.network.idle_connection_timeout_secs,
      "max_established_per_peer" => c.network.max_established_per_peer,
      "max_established_incoming" => c.network.max_established_incoming,
      "max_established_outgoing" => c.network.max_established_outgoing,
      "max_pending_incoming" => c.network.max_pending_incoming,
      "max_pending_outgoing" => c.network.max_pending_outgoing,
      "memory_max_percentage" => c.network.memory_max_percentage,
      # Discovery
      "enable_mdns" => c.discovery.enable_mdns,
      "mdns_auto_dial" => c.discovery.mdns_auto_dial,
      "enable_kademlia" => c.discovery.enable_kademlia,
      "bootstrap_peers" => c.discovery.bootstrap_peers,
      "dht_state_path" => c.discovery.dht_state_path,
      # Gossipsub
      "gossipsub_topics" => c.gossipsub.topics,
      "gossipsub_mesh_n" => c.gossipsub.mesh_n,
      "gossipsub_mesh_n_low" => c.gossipsub.mesh_n_low,
      "gossipsub_mesh_n_high" => c.gossipsub.mesh_n_high,
      "gossipsub_gossip_lazy" => c.gossipsub.gossip_lazy,
      "gossipsub_max_transmit_size" => c.gossipsub.max_transmit_size,
      "gossipsub_heartbeat_interval_ms" => c.gossipsub.heartbeat_interval_ms,
      "gossipsub_peer_score_disabled" => c.gossipsub.peer_score_disabled,
      "gossipsub_peer_score" => c.gossipsub.peer_score,
      "gossipsub_thresholds" => c.gossipsub.thresholds,
      # Request-Response RPC
      "rpc_protocol_name" => c.request_response.protocol_name,
      "rpc_request_timeout_secs" => c.request_response.request_timeout_secs,
      # Relay
      "enable_relay_client" => c.relay.enable_relay_client,
      "enable_relay_server" => c.relay.enable_relay_server,
      "relay_peers" => c.relay.relay_peers,
      "relay_max_reservations" => c.relay.relay_max_reservations,
      "relay_max_circuits" => c.relay.relay_max_circuits,
      "relay_max_circuit_duration_secs" => c.relay.relay_max_circuit_duration_secs,
      "relay_max_circuit_bytes" => c.relay.relay_max_circuit_bytes,
      # Rendezvous
      "enable_rendezvous" => c.rendezvous.enable,
      "rendezvous_namespace" => c.rendezvous.namespace,
      "rendezvous_ttl" => c.rendezvous.ttl,
      "rendezvous_peers" => c.rendezvous.peers,
      # Protocol enables
      "enable_autonat" => c.enable_autonat,
      "enable_autonat_server" => c.enable_autonat_server,
      "enable_upnp" => c.enable_upnp,
      "enable_websocket" => c.enable_websocket,
      "enable_rendezvous_server" => c.enable_rendezvous_server
    }
  end
end

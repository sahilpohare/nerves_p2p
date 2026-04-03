defmodule ElixirRpc.Discovery do
  @moduledoc """
  Pluggable peer discovery coordinator for P2P mesh networking.

  This module provides an extensible discovery system that supports multiple
  discovery backends (mDNS, DHT, gossip, etc.) through a behaviour-based
  plugin architecture.

  ## Architecture

  The discovery system uses three key abstractions:

  1. **Discovery.Provider** - Behaviour for discovery backends
  2. **Discovery.Protocol** - Protocol for peer/capability representation
  3. **Discovery Coordinator** - This module, orchestrates all providers

  ## Pluggable Providers

  Each discovery provider implements the `ElixirRpc.Discovery.Provider` behaviour:

  - `MdnsProvider` - Local network discovery via mDNS (fast, local-only)
  - `DhtProvider` - Distributed discovery via Kademlia DHT (global, persistent)
  - Custom providers can be added by implementing the behaviour

  ## Usage

  ```elixir
  # Start discovery with multiple providers
  Discovery.start_link(providers: [MdnsProvider, DhtProvider])

  # Advertise this node
  Discovery.advertise_self()

  # Advertise a capability
  Discovery.advertise_capability(:camera, %{resolution: "1080p"})

  # Find peers with capability
  {:ok, peers} = Discovery.find_capability(:camera)

  # Find a specific peer
  {:ok, peer_info} = Discovery.find_peer(:node_name@host)

  # Get all discovered peers
  peers = Discovery.get_discovered_peers()
  ```

  ## Extensibility

  To add a new discovery mechanism:

  1. Implement `ElixirRpc.Discovery.Provider` behaviour
  2. Add it to the providers list in config or startup
  3. No changes needed to core Discovery module

  Example:
  ```elixir
  defmodule MyCustomDiscovery do
    @behaviour ElixirRpc.Discovery.Provider

    @impl true
    def init(opts), do: {:ok, %{}}

    @impl true
    def advertise_self(state, peer_info), do: {:ok, state}

    @impl true
    def advertise_capability(state, capability, metadata), do: {:ok, state}

    @impl true
    def find_capability(state, capability), do: {:ok, [], state}

    @impl true
    def find_peer(state, node_name), do: {:error, :not_found, state}

    @impl true
    def get_discovered_peers(state), do: {[], state}
  end
  ```
  """

  use GenServer
  require Logger

  alias ElixirRpc.Discovery.PeerInfo

  defmodule State do
    @moduledoc false
    defstruct [
      :providers,           # Map of provider_module => provider_state
      :discovered_peers,    # MapSet of %PeerInfo{}
      :capabilities,        # Map of capability => [%PeerInfo{}]
      :local_capabilities,  # MapSet of advertised capabilities
      :subscribers          # List of PIDs subscribed to discovery events
    ]
  end

  ## Client API

  @doc """
  Start the discovery coordinator with configured providers.

  Options:
  - `:providers` - List of provider modules (default: [MdnsProvider, DhtProvider])
  - `:name` - GenServer name (default: __MODULE__)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Advertise this node's presence across all discovery providers.
  """
  @spec advertise_self() :: :ok | {:error, term()}
  def advertise_self do
    GenServer.call(__MODULE__, :advertise_self)
  end

  @doc """
  Advertise a capability for this node across all providers.
  """
  @spec advertise_capability(atom(), map()) :: :ok | {:error, term()}
  def advertise_capability(capability, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:advertise_capability, capability, metadata})
  end

  @doc """
  Find peers that advertise the given capability.
  Queries all providers and aggregates results.
  """
  @spec find_capability(atom()) :: {:ok, list(PeerInfo.t())} | {:error, term()}
  def find_capability(capability) do
    GenServer.call(__MODULE__, {:find_capability, capability})
  end

  @doc """
  Find a specific peer by node name.
  Queries all providers until found.
  """
  @spec find_peer(atom()) :: {:ok, PeerInfo.t()} | {:error, :not_found}
  def find_peer(node_name) do
    GenServer.call(__MODULE__, {:find_peer, node_name})
  end

  @doc """
  Get all discovered peers from all providers.
  """
  @spec get_discovered_peers() :: list(PeerInfo.t())
  def get_discovered_peers do
    GenServer.call(__MODULE__, :get_discovered_peers)
  end

  @doc """
  Subscribe to discovery events (peer_discovered, peer_lost, capability_found).
  """
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Trigger a discovery scan across all providers.
  """
  @spec scan() :: :ok
  def scan do
    GenServer.cast(__MODULE__, :scan)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Discovery coordinator")

    # Get configured providers or use defaults
    provider_modules = Keyword.get(opts, :providers, [
      ElixirRpc.Discovery.MdnsProvider,
      ElixirRpc.Discovery.DhtProvider
    ])

    # Initialize each provider
    providers =
      Enum.reduce(provider_modules, %{}, fn module, acc ->
        case module.init(opts) do
          {:ok, provider_state} ->
            Logger.info("Initialized discovery provider: #{inspect(module)}")
            Map.put(acc, module, provider_state)

          {:error, reason} ->
            Logger.warning("Failed to initialize provider #{inspect(module)}: #{inspect(reason)}")
            acc
        end
      end)

    state = %State{
      providers: providers,
      discovered_peers: MapSet.new(),
      capabilities: %{},
      local_capabilities: MapSet.new(),
      subscribers: []
    }

    # Schedule periodic discovery scan
    schedule_scan(30_000)

    # Advertise self after initialization
    send(self(), :advertise_self_initial)

    {:ok, state}
  end

  @impl true
  def handle_call(:advertise_self, _from, state) do
    peer_info = build_peer_info(state)

    # Advertise across all providers
    {results, new_providers} =
      Enum.map_reduce(state.providers, %{}, fn {module, provider_state}, acc ->
        case module.advertise_self(provider_state, peer_info) do
          {:ok, new_state} ->
            {{module, :ok}, Map.put(acc, module, new_state)}

          {:error, reason} ->
            Logger.warning("Provider #{inspect(module)} failed to advertise: #{inspect(reason)}")
            {{module, {:error, reason}}, Map.put(acc, module, provider_state)}
        end
      end)

    # Check if any succeeded
    success = Enum.any?(results, fn {_mod, result} -> result == :ok end)
    reply = if success, do: :ok, else: {:error, :all_providers_failed}

    {:reply, reply, %{state | providers: new_providers}}
  end

  @impl true
  def handle_call({:advertise_capability, capability, metadata}, _from, state) do
    # Advertise across all providers
    {results, new_providers} =
      Enum.map_reduce(state.providers, %{}, fn {module, provider_state}, acc ->
        case module.advertise_capability(provider_state, capability, metadata) do
          {:ok, new_state} ->
            {{module, :ok}, Map.put(acc, module, new_state)}

          {:error, reason} ->
            Logger.warning("Provider #{inspect(module)} failed to advertise capability: #{inspect(reason)}")
            {{module, {:error, reason}}, Map.put(acc, module, provider_state)}
        end
      end)

    success = Enum.any?(results, fn {_mod, result} -> result == :ok end)

    new_state = if success do
      %{state |
        providers: new_providers,
        local_capabilities: MapSet.put(state.local_capabilities, capability)
      }
    else
      %{state | providers: new_providers}
    end

    reply = if success, do: :ok, else: {:error, :all_providers_failed}
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:find_capability, capability}, _from, state) do
    # Query all providers and aggregate results
    {all_peers, new_providers} =
      Enum.flat_map_reduce(state.providers, %{}, fn {module, provider_state}, acc ->
        case module.find_capability(provider_state, capability) do
          {:ok, peers, new_state} ->
            {peers, Map.put(acc, module, new_state)}

          {:error, _reason, new_state} ->
            {[], Map.put(acc, module, new_state)}
        end
      end)

    # Deduplicate by peer_id and node
    unique_peers =
      all_peers
      |> Enum.uniq_by(& {&1.peer_id, &1.node})
      |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})

    {:reply, {:ok, unique_peers}, %{state | providers: new_providers}}
  end

  @impl true
  def handle_call({:find_peer, node_name}, _from, state) do
    # Try each provider until we find the peer
    result =
      Enum.reduce_while(state.providers, {:error, :not_found}, fn {module, provider_state}, _acc ->
        case module.find_peer(provider_state, node_name) do
          {:ok, peer_info, _new_state} ->
            {:halt, {:ok, peer_info}}

          {:error, :not_found, _new_state} ->
            {:cont, {:error, :not_found}}
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_discovered_peers, _from, state) do
    # Aggregate peers from all providers
    all_peers =
      Enum.flat_map(state.providers, fn {module, provider_state} ->
        {peers, _state} = module.get_discovered_peers(provider_state)
        peers
      end)

    unique_peers =
      all_peers
      |> Enum.uniq_by(& {&1.peer_id, &1.node})
      |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})

    {:reply, unique_peers, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_cast(:scan, state) do
    # Trigger scan on all providers that support it
    Enum.each(state.providers, fn {module, _provider_state} ->
      if function_exported?(module, :scan, 1) do
        send(self(), {:scan_provider, module})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:advertise_self_initial, state) do
    # Initial advertisement after startup
    advertise_self()
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan, state) do
    # Periodic scan
    scan()
    schedule_scan(30_000)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scan_provider, module}, state) do
    case Map.get(state.providers, module) do
      nil ->
        {:noreply, state}

      provider_state ->
        case module.scan(provider_state) do
          {:ok, new_state} ->
            new_providers = Map.put(state.providers, module, new_state)
            {:noreply, %{state | providers: new_providers}}

          {:error, _reason} ->
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead subscriber
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  ## Private Functions

  defp build_peer_info(state) do
    %PeerInfo{
      peer_id: get_peer_id(),
      node: node(),
      listen_addrs: get_listen_addrs(),
      capabilities: MapSet.to_list(state.local_capabilities),
      metadata: %{
        version: Application.spec(:elixir_rpc, :vsn) || "0.1.0",
        partisan_addrs: :partisan_config.get(:listen_addrs, [])
      },
      last_seen: DateTime.utc_now()
    }
  end

  defp get_peer_id do
    case ElixirRpc.Libp2pBridge.get_peer_id() do
      peer_id when is_binary(peer_id) -> peer_id
      _ -> nil
    end
  end

  defp get_listen_addrs do
    case ElixirRpc.Libp2pBridge.get_listen_addrs() do
      addrs when is_list(addrs) -> addrs
      _ -> []
    end
  end

  defp schedule_scan(interval) do
    Process.send_after(self(), :scan, interval)
  end

end

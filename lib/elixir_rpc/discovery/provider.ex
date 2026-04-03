defmodule ElixirRpc.Discovery.Provider do
  @moduledoc """
  Behaviour for pluggable discovery providers.

  This behaviour defines the contract that all discovery mechanisms must implement.
  It allows the system to be extended with new discovery backends without modifying
  core discovery logic.

  ## Implementing a Provider

  A discovery provider must implement all callbacks in this behaviour:

  ```elixir
  defmodule MyDiscoveryProvider do
    @behaviour ElixirRpc.Discovery.Provider

    alias ElixirRpc.Discovery.PeerInfo

    @impl true
    def init(opts) do
      {:ok, %{}}
    end

    @impl true
    def advertise_self(state, peer_info) do
      {:ok, state}
    end

    @impl true
    def advertise_capability(state, capability, metadata) do
      {:ok, state}
    end

    @impl true
    def find_capability(state, capability) do
      {:ok, [], state}
    end

    @impl true
    def find_peer(state, node_name) do
      {:error, :not_found, state}
    end

    @impl true
    def get_discovered_peers(state) do
      {[], state}
    end
  end
  ```

  ## Built-in Providers

  - `ElixirRpc.Discovery.MdnsProvider` - Local network discovery via mDNS
  - `ElixirRpc.Discovery.DhtProvider` - Distributed discovery via Kademlia DHT
  """

  alias ElixirRpc.Discovery.PeerInfo

  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @callback advertise_self(state :: term(), peer_info :: PeerInfo.t()) ::
              {:ok, new_state :: term()} | {:error, reason :: term()}

  @callback advertise_capability(
              state :: term(),
              capability :: atom(),
              metadata :: map()
            ) ::
              {:ok, new_state :: term()} | {:error, reason :: term()}

  @callback find_capability(state :: term(), capability :: atom()) ::
              {:ok, peers :: list(PeerInfo.t()), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}

  @callback find_peer(state :: term(), node_name :: atom()) ::
              {:ok, peer :: PeerInfo.t(), new_state :: term()}
              | {:error, :not_found, new_state :: term()}

  @callback get_discovered_peers(state :: term()) ::
              {peers :: list(PeerInfo.t()), state :: term()}

  @callback scan(state :: term()) :: {:ok, new_state :: term()} | {:error, reason :: term()}

  @optional_callbacks [scan: 1]
end

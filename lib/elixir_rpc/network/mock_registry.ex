defmodule ElixirRpc.Network.MockRegistry do
  @moduledoc """
  In-memory peer registry for testing `ElixirRpc.Network.spawn/2` on `:host`.

  Peers are registered with a capability map and can be looked up by
  constraint matching. Backed by ETS so it survives GenServer restarts
  within the same VM session.

  ## Usage

      # Register mock peers at test setup
      MockRegistry.register("peer-camera", %{camera: true, cpu: 2})
      MockRegistry.register("peer-gpu",    %{gpu: true,    cpu: 8})

      # Network.spawn will automatically use this registry on :host
      {:ok, pid} = Network.spawn([camera: true], fn -> :ok end)
  """

  use GenServer

  @table :elixir_rpc_mock_peers

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a mock peer with `peer_id` and `capabilities` map.

  Capabilities are arbitrary key-value pairs that constraints are matched against.

      MockRegistry.register("cam-node", %{camera: true, cpu: 2})
  """
  @spec register(String.t(), map()) :: :ok
  def register(peer_id, capabilities) when is_binary(peer_id) and is_map(capabilities) do
    GenServer.call(__MODULE__, {:register, peer_id, capabilities})
  end

  @doc """
  Unregister a mock peer by `peer_id`.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(peer_id) do
    GenServer.call(__MODULE__, {:unregister, peer_id})
  end

  @doc """
  List all registered mock peers.
  """
  @spec list() :: [{String.t(), map()}]
  def list do
    :ets.tab2list(@table)
  end

  @doc """
  Find the first peer whose capabilities satisfy all `constraints`.

  Each constraint is `{capability, value}`. A peer satisfies a constraint when
  `Map.get(peer_capabilities, capability) >= value` for numeric values, or
  `Map.get(peer_capabilities, capability) == value` for other types.

  Returns `{:ok, {:local, peer_id}}` or `{:error, :no_matching_peer}`.
  """
  @spec find_peer(keyword()) :: {:ok, {:local, String.t()}} | {:error, :no_matching_peer}
  def find_peer(constraints) do
    match =
      :ets.tab2list(@table)
      |> Enum.find(fn {_peer_id, caps} -> satisfies?(caps, constraints) end)

    case match do
      {peer_id, _caps} -> {:ok, {:local, peer_id}}
      nil -> {:error, :no_matching_peer}
    end
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table if it doesn't exist yet
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, peer_id, capabilities}, _from, state) do
    :ets.insert(@table, {peer_id, capabilities})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, peer_id}, _from, state) do
    :ets.delete(@table, peer_id)
    {:reply, :ok, state}
  end

  ## Private

  defp satisfies?(capabilities, constraints) do
    Enum.all?(constraints, fn {cap, required} ->
      case Map.get(capabilities, cap) do
        nil -> false
        actual when is_number(actual) and is_number(required) -> actual >= required
        actual -> actual == required
      end
    end)
  end
end

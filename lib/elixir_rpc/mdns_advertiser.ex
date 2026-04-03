defmodule ElixirRpc.MdnsAdvertiser do
  @moduledoc """
  Advertises Partisan service via mDNS on Nerves targets.

  This module is responsible ONLY for advertising this node's
  Partisan service so other nodes can discover it.

  Discovery is handled by PeerManager.
  """

  use GenServer
  require Logger

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Only advertise on Nerves targets (not host mode)
    if Mix.target() != :host and Code.ensure_loaded?(MdnsLite) do
      # Wait longer for libp2p bridge and Partisan port configuration
      Process.send_after(self(), :advertise, 3000)
    end

    {:ok, %{advertised: false}}
  end

  @impl true
  def handle_info(:advertise, state) do
    case advertise_service() do
      :ok ->
        {:noreply, %{state | advertised: true}}

      {:error, :not_ready} ->
        # Retry after delay
        Process.send_after(self(), :advertise, 1000)
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  ## Private Functions

  defp advertise_service do
    node_name = :partisan_config.get(:name)
    listen_addrs = :partisan_config.get(:listen_addrs)

    if node_name == :undefined or listen_addrs == :undefined do
      {:error, :not_ready}
    else
      case get_partisan_port(listen_addrs) do
        {:ok, port} ->
          service = %{
            id: :partisan_peer,
            protocol: "partisan",
            transport: "tcp",
            port: port,
            txt_payload: [
              "node=#{node_name}",
              "version=#{Application.spec(:elixir_rpc, :vsn) || "0.1.0"}",
              "partisan_version=#{Application.spec(:partisan, :vsn) || "5.0"}",
              "port_source=libp2p"
            ]
          }

          # Use apply to avoid compiler warnings when MdnsLite is not available
          case apply(MdnsLite, :add_mdns_service, [service]) do
            :ok ->
              Logger.info(
                "Partisan service advertised via mDNS on port #{port} (libp2p-assigned)"
              )

              :ok

            {:error, reason} ->
              Logger.warning("Failed to advertise Partisan service: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, :no_port} ->
          Logger.warning("Partisan port not configured yet, will retry")
          {:error, :not_ready}
      end
    end
  end

  defp get_partisan_port([%{port: port} | _]) when is_integer(port) and port > 0,
    do: {:ok, port}

  defp get_partisan_port(_), do: {:error, :no_port}
end

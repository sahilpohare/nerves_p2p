defmodule ElixirRpc.Metrics do
  @moduledoc """
  Network metrics and observability.

  ## Usage

      {:ok, %{bytes_in: in, bytes_out: out}} = ElixirRpc.Metrics.bandwidth(node)
      {:ok, text} = ElixirRpc.Metrics.prometheus_scrape(node)

  """

  import ElixirRpc.Call, only: [safe_call: 2]

  @spec bandwidth(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def bandwidth(node) do
    case safe_call(node, :bandwidth_stats) do
      {:ok, bytes_in, bytes_out} -> {:ok, %{bytes_in: bytes_in, bytes_out: bytes_out}}
      {:error, _} = error -> error
    end
  end

  @spec prometheus_scrape(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def prometheus_scrape(node), do: safe_call(node, :prometheus_metrics)
end

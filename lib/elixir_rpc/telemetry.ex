defmodule ElixirRpc.Telemetry do
  @moduledoc """
  Telemetry event catalog for ElixirRpc.

  All events are prefixed with `[:elixir_rpc, ...]`.

  ## Events fired today

  ### `:telemetry.span/3` (fires `:start`, `:stop`, `:exception`)
  - `[:elixir_rpc, :node, :dial]` — outbound dial attempt
  - `[:elixir_rpc, :gossipsub, :publish]` — GossipSub publish

  ### `:telemetry.execute/3`
  - `[:elixir_rpc, :gossipsub, :subscribe]` — topic subscribe
  - `[:elixir_rpc, :gossipsub, :unsubscribe]` — topic unsubscribe
  - `[:elixir_rpc, :health, :check]` — health probe succeeded
  - `[:elixir_rpc, :health, :check_failed]` — health probe failed

  ## Attaching handlers

      :telemetry.attach_many(
        "my-handler",
        ElixirRpc.Telemetry.event_names(),
        &handle_event/4,
        nil
      )

  """

  @span_events [
    [:elixir_rpc, :node, :dial],
    [:elixir_rpc, :gossipsub, :publish]
  ]

  @execute_events [
    [:elixir_rpc, :gossipsub, :subscribe],
    [:elixir_rpc, :gossipsub, :unsubscribe],
    [:elixir_rpc, :health, :check],
    [:elixir_rpc, :health, :check_failed]
  ]

  @aspirational_events [
    [:elixir_rpc, :connection, :established],
    [:elixir_rpc, :connection, :closed],
    [:elixir_rpc, :gossipsub, :message_received],
    [:elixir_rpc, :dht, :query_completed],
    [:elixir_rpc, :node, :started],
    [:elixir_rpc, :node, :stopped]
  ]

  @span_suffixes [:start, :stop, :exception]

  @spec event_names() :: [[atom()]]
  def event_names do
    span_expanded =
      for event <- @span_events, suffix <- @span_suffixes do
        event ++ [suffix]
      end

    span_expanded ++ @execute_events
  end

  @spec aspirational_event_names() :: [[atom()]]
  def aspirational_event_names, do: @aspirational_events
end

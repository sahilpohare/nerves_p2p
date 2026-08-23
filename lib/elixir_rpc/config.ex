defmodule ElixirRpc.Config do
  @moduledoc """
  Centralized accessors for `ElixirRpc` application configuration.

  All `Application.get_env` reads for `:elixir_rpc` SHOULD route through
  this module for grep-able boundary discipline.
  """

  @default_native_module ElixirRpc.P2P.Native.Nif
  @default_keypair_storage ElixirRpc.Keypair.Storage.File
  @default_task_tracker_clock ElixirRpc.Clock.System

  @spec default_native_module() :: module()
  def default_native_module,
    do: Application.get_env(:elixir_rpc, :native_module, @default_native_module)

  @spec keypair_storage() :: module()
  def keypair_storage do
    :elixir_rpc
    |> Application.get_env(ElixirRpc.Keypair, [])
    |> Keyword.get(:storage, @default_keypair_storage)
  end

  @spec task_tracker_clock() :: module()
  def task_tracker_clock do
    :elixir_rpc
    |> Application.get_env(ElixirRpc.OTP.TaskTracker, [])
    |> Keyword.get(:clock, @default_task_tracker_clock)
  end

  @spec dht_state_storage() :: module()
  def dht_state_storage do
    :elixir_rpc
    |> Application.get_env(ElixirRpc.Node.DhtState, [])
    |> Keyword.get(:storage, @default_keypair_storage)
  end
end

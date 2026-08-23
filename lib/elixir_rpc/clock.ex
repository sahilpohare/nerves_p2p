defmodule ElixirRpc.Clock do
  @moduledoc """
  Behaviour for monotonic-time sources.

  Abstracts `System.monotonic_time/1` so callers can be tested with a
  controllable clock.
  """

  @type unit :: :millisecond | :microsecond | :nanosecond

  @callback monotonic_time(unit()) :: integer()
end

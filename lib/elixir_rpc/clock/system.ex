defmodule ElixirRpc.Clock.System do
  @moduledoc false

  @behaviour ElixirRpc.Clock

  @impl true
  def monotonic_time(unit), do: System.monotonic_time(unit)
end

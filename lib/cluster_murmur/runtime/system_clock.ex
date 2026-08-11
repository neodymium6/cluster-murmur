defmodule ClusterMurmur.Runtime.SystemClock do
  @moduledoc "The production wall and monotonic clock implementation."

  @behaviour ClusterMurmur.Clock
  @behaviour ClusterMurmur.Runtime.Clock

  @impl true
  def utc_now, do: DateTime.utc_now()

  @impl true
  def now, do: utc_now()

  @impl true
  def monotonic_time_ms, do: System.monotonic_time(:millisecond)
end

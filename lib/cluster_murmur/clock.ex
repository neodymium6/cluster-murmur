defmodule ClusterMurmur.Clock do
  @moduledoc """
  Time source used by scheduling and conversation policy.

  Runtime components depend on this behaviour so tests and replay can supply a
  deterministic clock.
  """

  @callback now() :: DateTime.t()
  @callback monotonic_time() :: integer()
end

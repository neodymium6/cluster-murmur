defmodule ClusterMurmur.Triggers.ActiveHours do
  @moduledoc """
  A validated daily local-time window for a stochastic trigger.

  Minute offsets are normalized from strict `HH:MM` values. A window may cross
  midnight; equal endpoints are rejected at the configuration boundary.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:start_minute, :end_minute, :timezone]
  defstruct [:start_minute, :end_minute, :timezone]

  @type t :: %__MODULE__{
          start_minute: 0..1439,
          end_minute: 0..1439,
          timezone: Calendar.time_zone()
        }
end

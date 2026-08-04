defmodule ClusterMurmur.Triggers.StochasticTrigger do
  @moduledoc """
  A validated shifted-exponential trigger that emits an event.

  This domain value contains scheduling parameters only. Sampling, persistence,
  and event execution remain separate runtime responsibilities.
  """

  alias ClusterMurmur.Triggers.{ActiveHours, EmittedEvent}

  @derive {Inspect, only: []}
  @enforce_keys [
    :id,
    :distribution,
    :mean_interval_ms,
    :minimum_interval_ms,
    :active_hours,
    :daily_limit,
    :action,
    :event
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          distribution: :shifted_exponential,
          mean_interval_ms: pos_integer(),
          minimum_interval_ms: pos_integer(),
          active_hours: ActiveHours.t() | nil,
          daily_limit: pos_integer() | nil,
          action: :emit_event,
          event: EmittedEvent.t()
        }
end

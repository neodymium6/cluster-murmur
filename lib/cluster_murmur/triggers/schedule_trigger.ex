defmodule ClusterMurmur.Triggers.ScheduleTrigger do
  @moduledoc """
  A validated recurring schedule that emits an application-owned event.

  Cron parsing and timezone validation happen at the configuration boundary.
  This value does not execute the schedule or perform external I/O.
  """

  alias ClusterMurmur.Triggers.EmittedEvent

  @derive {Inspect, only: []}
  @enforce_keys [:id, :cron, :timezone, :action, :event]
  defstruct [:id, :cron, :timezone, :action, :event]

  @type t :: %__MODULE__{
          id: String.t(),
          cron: Crontab.CronExpression.t(),
          timezone: Calendar.time_zone(),
          action: :emit_event,
          event: EmittedEvent.t()
        }
end

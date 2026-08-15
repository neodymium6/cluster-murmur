defmodule ClusterMurmur.Generation.FactProjection do
  @moduledoc """
  Redacted allowlisted event facts for generation input.

  Event identity, source, deduplication, correlation, labels, and observation
  metadata are deliberately absent from this projection.
  """

  @derive {Inspect, only: [:event_type, :severity, :occurred_at]}
  @enforce_keys [
    :event_type,
    :subject,
    :group,
    :severity,
    :previous_state,
    :current_state,
    :details,
    :occurred_at,
    :occurred_at_timezone
  ]
  defstruct [
    :event_type,
    :subject,
    :group,
    :severity,
    :previous_state,
    :current_state,
    :details,
    :occurred_at,
    :occurred_at_timezone
  ]

  @type t :: %__MODULE__{
          event_type: String.t(),
          subject: String.t() | nil,
          group: String.t() | nil,
          severity: String.t() | nil,
          previous_state: term(),
          current_state: term(),
          details: map(),
          occurred_at: DateTime.t(),
          occurred_at_timezone: Calendar.time_zone()
        }
end

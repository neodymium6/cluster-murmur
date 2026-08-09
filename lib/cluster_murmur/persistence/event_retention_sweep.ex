defmodule ClusterMurmur.Persistence.EventRetentionSweep do
  @moduledoc """
  Redacted persistence state for the single bounded event-retention sweep.

  The cursor is internal repository state. It is never returned by the store
  or retained in runtime status.
  """

  use Ecto.Schema

  @derive {Inspect, only: []}
  @primary_key {:scope, :string, autogenerate: false, redact: true}

  schema "event_retention_sweeps" do
    field :cursor_occurred_at, :utc_datetime_usec, redact: true
    field :cursor_event_id, :string, redact: true
    field :swept_at, :utc_datetime_usec, redact: true
  end

  @type t :: %__MODULE__{
          scope: String.t() | nil,
          cursor_occurred_at: DateTime.t() | nil,
          cursor_event_id: String.t() | nil,
          swept_at: DateTime.t() | nil
        }
end

defmodule ClusterMurmur.Persistence.EventDispatch do
  @moduledoc """
  Redacted durable outbox state for one immutable event.

  Dispatch workers receive separate opaque claims rather than mutable records.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.Validator

  @derive {Inspect, only: [:status]}
  @primary_key {:event_id, :string, autogenerate: false, redact: true}
  @fields [
    :event_id,
    :status,
    :enqueued_at,
    :claim_token,
    :claim_started_at,
    :claim_expires_at,
    :completed_at
  ]

  schema "event_dispatches" do
    field :status, Ecto.Enum, values: [:pending, :claimed, :completed], redact: true
    field :enqueued_at, :utc_datetime_usec, redact: true
    field :claim_token, :string, redact: true
    field :claim_started_at, :utc_datetime_usec, redact: true
    field :claim_expires_at, :utc_datetime_usec, redact: true
    field :completed_at, :utc_datetime_usec, redact: true
  end

  @type status :: :pending | :claimed | :completed
  @type t :: %__MODULE__{
          event_id: String.t() | nil,
          status: status() | nil,
          enqueued_at: DateTime.t() | nil,
          claim_token: String.t() | nil,
          claim_started_at: DateTime.t() | nil,
          claim_expires_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @doc false
  def enqueue_changeset(%__MODULE__{} = dispatch, event_id, enqueued_at) do
    dispatch
    |> cast(
      %{event_id: event_id, status: :pending, enqueued_at: enqueued_at},
      @fields
    )
    |> validate_required([:event_id, :status, :enqueued_at])
    |> validate_change(:event_id, &validate_event_id/2)
    |> validate_change(:enqueued_at, &validate_datetime/2)
    |> check_constraint(:event_id, name: "event_dispatches_event_id")
    |> check_constraint(:status, name: "event_dispatches_status")
    |> check_constraint(:enqueued_at, name: "event_dispatches_enqueued_at")
    |> unique_constraint(:event_id)
  end

  defp validate_event_id(:event_id, event_id) do
    case Validator.validate_id(event_id) do
      :ok -> []
      _failure -> [event_id: "is invalid"]
    end
  end

  defp validate_datetime(field, value) do
    if DateTimeValidator.validate_storage_utc(value) == :ok,
      do: [],
      else: [{field, "is invalid"}]
  end
end

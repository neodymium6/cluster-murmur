defmodule ClusterMurmur.Persistence.PublicationAttemptRecord do
  @moduledoc """
  Redacted durable lifecycle for one Discord publication attempt.

  One message has at most one attempt. Prepared and dispatching states are
  deliberately distinguishable from known success, classified failure, and an
  ambiguous interrupted outcome.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.{MessageRecord, MessageRecordValidator}

  @derive {Inspect, only: [:status]}
  @primary_key false
  @fields [:message_id, :status, :started_at, :completed_at, :error_class]

  schema "publication_attempts" do
    field :message_id, :integer, primary_key: true, redact: true
    field :status, Ecto.Enum, values: [:started, :dispatching, :succeeded, :failed, :ambiguous]
    field :started_at, :utc_datetime_usec, redact: true
    field :completed_at, :utc_datetime_usec, redact: true

    field :error_class, Ecto.Enum,
      values: [
        :authentication_failed,
        :invalid_request,
        :invalid_response,
        :rate_limited,
        :timeout,
        :unavailable,
        :interrupted
      ],
      redact: true
  end

  @type status :: :started | :dispatching | :succeeded | :failed | :ambiguous
  @type t :: %__MODULE__{
          message_id: pos_integer() | nil,
          status: status() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          error_class: atom() | nil
        }

  @doc "Builds a started attempt for one exact loaded unpublished message."
  @spec start_changeset(t(), term(), term()) :: Ecto.Changeset.t()
  def start_changeset(%__MODULE__{} = attempt, %MessageRecord{} = message, started_at) do
    if attempt == %__MODULE__{} and MessageRecordValidator.validate(message) == :ok and
         message.discord_message_id == nil and
         DateTimeValidator.validate_storage_utc(started_at) == :ok do
      attempt
      |> cast(
        %{
          message_id: message.id,
          status: :started,
          started_at: started_at,
          completed_at: nil,
          error_class: nil
        },
        @fields
      )
      |> validate_required([:message_id, :status, :started_at])
      |> check_constraint(:status, name: "publication_attempts_status")
      |> check_constraint(:started_at, name: "publication_attempts_started_at")
      |> check_constraint(:completed_at, name: "publication_attempts_completed_at")
      |> check_constraint(:error_class, name: "publication_attempts_error_class")
      |> foreign_key_constraint(:message_id)
      |> unique_constraint(:message_id, name: :publication_attempts_message_id_index)
    else
      invalid_changeset(attempt)
    end
  rescue
    _error -> invalid_changeset(attempt)
  catch
    _kind, _reason -> invalid_changeset(attempt)
  end

  def start_changeset(%__MODULE__{} = attempt, _message, _started_at),
    do: invalid_changeset(attempt)

  defp invalid_changeset(attempt), do: attempt |> change() |> add_error(:base, "is invalid")
end

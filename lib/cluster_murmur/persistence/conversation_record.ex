defmodule ClusterMurmur.Persistence.ConversationRecord do
  @moduledoc """
  Redacted durable lifecycle metadata for one bounded conversation.

  New records represent only a pristine starting conversation. Participants and
  messages are not silently discarded into this metadata-only table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.Conversations.{Conversation, Validator}

  @derive {Inspect, only: []}
  @primary_key {:id, :string, autogenerate: false, redact: true}
  @fields [
    :id,
    :root_event_id,
    :status,
    :turn_count,
    :llm_call_count,
    :started_at,
    :completed_at
  ]

  schema "conversations" do
    field :root_event_id, :string, redact: true

    field :status, Ecto.Enum,
      values: [:starting, :generating, :waiting, :completed, :cancelled, :failed],
      redact: true

    field :turn_count, :integer, redact: true
    field :llm_call_count, :integer, redact: true
    field :started_at, :utc_datetime_usec, redact: true
    field :completed_at, :utc_datetime_usec, redact: true
  end

  @type status :: :starting | :generating | :waiting | :completed | :cancelled | :failed
  @type t :: %__MODULE__{
          id: String.t() | nil,
          root_event_id: String.t() | nil,
          status: status() | nil,
          turn_count: non_neg_integer() | nil,
          llm_call_count: non_neg_integer() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @doc "Builds a redacted record for one pristine starting conversation."
  @spec start_changeset(t(), term()) :: Ecto.Changeset.t()
  def start_changeset(%__MODULE__{} = record, %Conversation{} = conversation) do
    if pristine_record?(record) and pristine_start?(conversation) and
         Validator.validate(conversation) == :ok do
      record
      |> cast(
        %{
          id: conversation.id,
          root_event_id: conversation.root_event_id,
          status: :starting,
          turn_count: 0,
          llm_call_count: 0,
          started_at: conversation.started_at,
          completed_at: nil
        },
        @fields
      )
      |> validate_required([
        :id,
        :root_event_id,
        :status,
        :turn_count,
        :llm_call_count,
        :started_at
      ])
      |> check_constraints()
    else
      invalid_changeset(record)
    end
  rescue
    _error -> invalid_changeset(record)
  catch
    _kind, _reason -> invalid_changeset(record)
  end

  def start_changeset(%__MODULE__{} = record, _conversation), do: invalid_changeset(record)

  defp pristine_record?(record), do: record == %__MODULE__{}

  defp pristine_start?(conversation) do
    conversation.status == :starting and conversation.last_message_at == nil and
      conversation.turn_count == 0 and conversation.llm_call_count == 0 and
      conversation.participants == [] and conversation.messages == []
  end

  defp check_constraints(changeset) do
    changeset
    |> check_constraint(:id, name: "conversations_id")
    |> check_constraint(:root_event_id, name: "conversations_root_event_id")
    |> check_constraint(:status, name: "conversations_status")
    |> check_constraint(:turn_count, name: "conversations_turn_count")
    |> check_constraint(:llm_call_count, name: "conversations_llm_call_count")
    |> check_constraint(:started_at, name: "conversations_started_at")
    |> check_constraint(:completed_at, name: "conversations_completed_at")
  end

  defp invalid_changeset(record) do
    record
    |> change()
    |> add_error(:base, "is invalid")
  end
end

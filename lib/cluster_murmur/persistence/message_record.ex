defmodule ClusterMurmur.Persistence.MessageRecord do
  @moduledoc """
  Redacted persistence representation of one bounded generated message.

  Construction requires the complete runtime message validator. Repository
  insertion and publication-ID updates remain separate narrow store concerns.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.Messages.{Message, Validator}

  @derive {Inspect, only: [:origin]}
  @primary_key {:id, :id, autogenerate: true, redact: true}
  @fields [
    :conversation_id,
    :persona_id,
    :origin,
    :content,
    :discord_message_id,
    :inserted_at
  ]

  schema "messages" do
    field :conversation_id, :string, redact: true
    field :persona_id, :string, redact: true
    field :origin, Ecto.Enum, values: [:llm, :fallback]
    field :content, :string, redact: true
    field :discord_message_id, :string, redact: true
    field :inserted_at, :utc_datetime_usec, redact: true
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          conversation_id: String.t() | nil,
          persona_id: String.t() | nil,
          origin: Message.origin() | nil,
          content: String.t() | nil,
          discord_message_id: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc "Builds a redacted persistence changeset from one validated message."
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = record, %Message{} = message) do
    if pristine_record?(record) and Validator.validate(message) == :ok do
      record
      |> cast(Map.from_struct(message), @fields)
      |> validate_required([:conversation_id, :persona_id, :origin, :content, :inserted_at])
      |> check_constraints()
    else
      invalid_changeset(record)
    end
  rescue
    _error -> invalid_changeset(record)
  catch
    _kind, _reason -> invalid_changeset(record)
  end

  def changeset(%__MODULE__{} = record, _message), do: invalid_changeset(record)

  defp pristine_record?(record), do: record == %__MODULE__{}

  defp check_constraints(changeset) do
    changeset
    |> check_constraint(:conversation_id, name: "messages_conversation_id")
    |> check_constraint(:persona_id, name: "messages_persona_id")
    |> check_constraint(:origin, name: "messages_origin")
    |> check_constraint(:content, name: "messages_content")
    |> check_constraint(:discord_message_id, name: "messages_discord_message_id")
    |> check_constraint(:inserted_at, name: "messages_inserted_at")
    |> unique_constraint(:discord_message_id)
  end

  defp invalid_changeset(record) do
    record
    |> change()
    |> add_error(:base, "is invalid")
  end
end

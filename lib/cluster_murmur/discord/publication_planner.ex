defmodule ClusterMurmur.Discord.PublicationPlanner do
  @moduledoc """
  Plans one Discord publication from an exact durable message projection.

  A record that already has a Discord message ID is skipped without requiring
  current persona or webhook settings. An unpublished record is revalidated and
  converted into a fixed payload without executing external or storage effects.
  """

  alias ClusterMurmur.Discord.{PublicationPayload, WebhookSettings}
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Persistence.{MessageRecord, MessageRecordValidator}

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:record, :persona, :settings, :payload]
    defstruct [:record, :persona, :settings, :payload]

    @type t :: %__MODULE__{
            record: ClusterMurmur.Persistence.MessageRecord.t(),
            persona: ClusterMurmur.Personas.Persona.t(),
            settings: ClusterMurmur.Discord.WebhookSettings.t(),
            payload: ClusterMurmur.Discord.PublicationPayload.t()
          }
  end

  @type skip_reason :: :already_published
  @type error ::
          :invalid_message_record
          | :invalid_publication_payload
          | :invalid_webhook_settings

  @doc "Returns a redacted publication plan or skips a known published record."
  @spec plan(term(), term(), term()) ::
          {:ok, Plan.t()} | {:skip, skip_reason()} | {:error, error()}
  def plan(%MessageRecord{} = record, persona, settings) do
    with :ok <- MessageRecordValidator.validate(record) do
      plan_record(record, persona, settings)
    end
  end

  def plan(_record, _persona, _settings), do: {:error, :invalid_message_record}

  defp plan_record(%MessageRecord{discord_message_id: discord_message_id}, _persona, _settings)
       when is_binary(discord_message_id),
       do: {:skip, :already_published}

  defp plan_record(%MessageRecord{discord_message_id: nil} = record, persona, settings) do
    with :ok <- WebhookSettings.validate(settings),
         {:ok, payload} <- PublicationPayload.build(to_message(record), persona) do
      {:ok, %Plan{record: record, persona: persona, settings: settings, payload: payload}}
    end
  end

  defp to_message(record) do
    %Message{
      conversation_id: record.conversation_id,
      persona_id: record.persona_id,
      origin: record.origin,
      content: record.content,
      discord_message_id: record.discord_message_id,
      inserted_at: record.inserted_at
    }
  end
end

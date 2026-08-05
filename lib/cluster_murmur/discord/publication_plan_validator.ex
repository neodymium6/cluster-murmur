defmodule ClusterMurmur.Discord.PublicationPlanValidator do
  @moduledoc """
  Revalidates one exact publication plan against current trusted inputs.

  The caller supplies a freshly loaded durable message and current exact persona
  and webhook settings independently from the plan snapshot.
  """

  alias ClusterMurmur.Discord.{PublicationPayload, WebhookSettings}
  alias ClusterMurmur.Discord.PublicationPlanner.Plan
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Persistence.MessageRecordValidator
  alias ClusterMurmur.Personas.Validator, as: PersonaValidator

  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error :: :invalid_publication_plan

  @doc "Validates a plan against independently obtained current execution inputs."
  @spec validate(term(), term(), term(), term()) :: :ok | {:error, error()}
  def validate(%Plan{} = plan, current_record, current_persona, current_settings) do
    with true <- exact?(plan),
         :ok <- MessageRecordValidator.validate(current_record),
         true <- current_record.discord_message_id == nil,
         :ok <- PersonaValidator.validate(current_persona),
         :ok <- WebhookSettings.validate(current_settings),
         true <- plan.record == current_record,
         true <- plan.persona == current_persona,
         true <- plan.settings == current_settings,
         {:ok, expected_payload} <-
           PublicationPayload.build(to_message(current_record), current_persona),
         true <- expected_payload == plan.payload do
      :ok
    else
      _failure -> {:error, :invalid_publication_plan}
    end
  rescue
    _error -> {:error, :invalid_publication_plan}
  catch
    _kind, _reason -> {:error, :invalid_publication_plan}
  end

  def validate(_plan, _current_record, _current_persona, _current_settings),
    do: {:error, :invalid_publication_plan}

  defp exact?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
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

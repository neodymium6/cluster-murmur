defmodule ClusterMurmur.Generation.StarterMessagePersister do
  @moduledoc """
  Atomically appends one generated starter message through a narrow store.

  The boundary revalidates the exact generated capability, delegates the
  unpublished message and its original loaded conversation to the injected
  store, and accepts only correlated loaded message and advanced-conversation
  records. It does not publish or record a persona cooldown.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Generation.StarterGenerator
  alias ClusterMurmur.Generation.StarterGenerator.Generated

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    MessageRecord,
    MessageRecordValidator,
    MessageStore
  }

  defmodule Persisted do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:generated, :message, :conversation]
    defstruct [:generated, :message, :conversation]

    @type t :: %__MODULE__{
            generated: ClusterMurmur.Generation.StarterGenerator.Generated.t(),
            message: ClusterMurmur.Persistence.MessageRecord.t(),
            conversation: ClusterMurmur.Persistence.ConversationRecord.t()
          }
  end

  @persisted_keys Persisted.__struct__() |> Map.keys()
  @persisted_key_count length(@persisted_keys)

  @type error ::
          :conversation_conflict
          | :conversation_limit
          | :invalid_conversation_record
          | :invalid_message
          | :invalid_message_record
          | :invalid_starter_message
          | :message_conflict
          | :storage_unavailable

  @doc "Appends one generated starter and advances the conversation counters once."
  @spec persist(term(), term(), term(), module()) ::
          {:ok, Persisted.t()} | {:error, error()}
  def persist(generated, configuration, cooldowns, store \\ MessageStore)

  def persist(%Generated{} = generated, %Configuration{} = configuration, cooldowns, store)
      when is_atom(store) do
    with :ok <- StarterGenerator.validate(generated, configuration, cooldowns),
         :ok <- validate_store(store),
         {:ok, {%MessageRecord{} = message, %ConversationRecord{} = conversation}} <-
           append(store, generated),
         :ok <- validate_store_result(message, conversation, generated),
         persisted = %Persisted{
           generated: generated,
           message: message,
           conversation: conversation
         },
         :ok <- validate(persisted, configuration, cooldowns) do
      {:ok, persisted}
    else
      {:error, reason}
      when reason in [
             :conversation_conflict,
             :conversation_limit,
             :invalid_conversation_record,
             :invalid_message,
             :invalid_message_record,
             :invalid_starter_message,
             :message_conflict,
             :storage_unavailable
           ] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  def persist(_generated, _configuration, _cooldowns, _store),
    do: {:error, :invalid_starter_message}

  @doc "Revalidates exact loaded append results against the generated capability."
  @spec validate(term(), term(), term()) :: :ok | {:error, :invalid_starter_message}
  def validate(%Persisted{} = persisted, %Configuration{} = configuration, cooldowns) do
    if exact_persisted?(persisted) and
         StarterGenerator.validate(persisted.generated, configuration, cooldowns) == :ok and
         correlated_message?(persisted.message, persisted.generated) and
         correlated_conversation?(persisted.conversation, persisted.generated) do
      :ok
    else
      {:error, :invalid_starter_message}
    end
  rescue
    _error -> {:error, :invalid_starter_message}
  catch
    _kind, _reason -> {:error, :invalid_starter_message}
  end

  def validate(_persisted, _configuration, _cooldowns),
    do: {:error, :invalid_starter_message}

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :append, 2),
      do: :ok,
      else: {:error, :storage_unavailable}
  end

  defp append(store, generated) do
    store.append(generated.plan.started.conversation, generated.message)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp correlated_message?(record, generated) do
    message = generated.message

    MessageRecordValidator.validate(record) == :ok and
      record.conversation_id === message.conversation_id and
      record.persona_id === message.persona_id and record.origin === message.origin and
      record.content === message.content and
      record.discord_message_id === message.discord_message_id and
      same_datetime?(record.inserted_at, message.inserted_at)
  end

  defp validate_store_result(message, conversation, generated) do
    cond do
      not correlated_message?(message, generated) ->
        {:error, :invalid_message_record}

      not correlated_conversation?(conversation, generated) ->
        {:error, :invalid_conversation_record}

      true ->
        :ok
    end
  end

  defp correlated_conversation?(record, generated) do
    original = generated.plan.started.conversation

    ConversationRecordValidator.validate_active(record) == :ok and
      record.id === original.id and record.root_event_id === original.root_event_id and
      record.status === original.status and record.turn_count === original.turn_count + 1 and
      record.llm_call_count === original.llm_call_count + 1 and
      same_datetime?(record.started_at, original.started_at) and is_nil(record.completed_at)
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp exact_persisted?(persisted) do
    map_size(persisted) == @persisted_key_count and
      Enum.all?(@persisted_keys, &Map.has_key?(persisted, &1))
  end
end

defmodule ClusterMurmur.Persistence.MessageStore do
  @moduledoc """
  Persists and restores bounded messages through narrow capability-based operations.

  Appends require an exact loaded active conversation, publication updates
  require an exact unpublished message, and history reads require an exact
  conversation in any lifecycle state. The store does not select a persona,
  generate content, publish to Discord, or decide whether another turn is
  allowed by configured policy.
  """

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]
  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    MessageRecord,
    MessageRecordValidator
  }

  alias ClusterMurmur.Repo

  @max_conversation_messages 12
  @max_safe_integer DomainLimits.max_safe_integer()
  @conversation_fields [
    :id,
    :root_event_id,
    :status,
    :turn_count,
    :llm_call_count,
    :started_at,
    :completed_at
  ]
  @message_fields [
    :conversation_id,
    :persona_id,
    :origin,
    :content,
    :discord_message_id,
    :inserted_at
  ]

  @type error ::
          :conversation_conflict
          | :conversation_limit
          | :invalid_conversation_record
          | :invalid_message
          | :invalid_message_record
          | :message_conflict
          | :publication_conflict
          | :invalid_publication_id
          | :storage_unavailable

  @doc "Appends one unpublished message and advances both durable counters once."
  @spec append(term(), term()) ::
          {:ok, {MessageRecord.t(), ConversationRecord.t()}} | {:error, error()}
  def append(conversation, message) do
    with :ok <- ConversationRecordValidator.validate_active(conversation),
         {:ok, changeset} <- validate_message(conversation, message),
         :ok <- validate_capacity(conversation) do
      persist(conversation, changeset)
    else
      {:error, reason}
      when reason in [
             :invalid_conversation_record,
             :invalid_message,
             :conversation_limit
           ] ->
        {:error, reason}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Records one canonical Discord message ID for an exact unpublished record."
  @spec record_publication(term(), term()) ::
          {:ok, MessageRecord.t()} | {:error, error()}
  def record_publication(record, discord_message_id) do
    with :ok <- MessageRecordValidator.validate(record),
         :ok <- require_unpublished(record),
         :ok <- validate_publication_id(record, discord_message_id) do
      persist_publication(record, discord_message_id)
    else
      {:error, reason}
      when reason in [
             :invalid_message_record,
             :publication_conflict,
             :invalid_publication_id
           ] ->
        {:error, reason}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Lists at most 12 latest messages for one exact conversation in chronological order."
  @spec list_for_conversation(term()) ::
          {:ok, [Message.t()]}
          | {:error,
             :conversation_conflict
             | :invalid_conversation_record
             | :invalid_message_record
             | :storage_unavailable}
  def list_for_conversation(conversation) do
    if ConversationRecordValidator.validate(conversation) == :ok do
      read_conversation_history(conversation)
    else
      {:error, :invalid_conversation_record}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp require_unpublished(%MessageRecord{discord_message_id: nil}), do: :ok
  defp require_unpublished(_record), do: {:error, :publication_conflict}

  defp validate_publication_id(record, discord_message_id) when is_binary(discord_message_id) do
    message = %Message{
      conversation_id: record.conversation_id,
      persona_id: record.persona_id,
      origin: record.origin,
      content: record.content,
      discord_message_id: discord_message_id,
      inserted_at: record.inserted_at
    }

    if MessageValidator.validate(message) == :ok,
      do: :ok,
      else: {:error, :invalid_publication_id}
  end

  defp validate_publication_id(_record, _discord_message_id),
    do: {:error, :invalid_publication_id}

  defp validate_message(conversation, message) do
    changeset = MessageRecord.changeset(%MessageRecord{}, message)

    if changeset.valid? and message.conversation_id == conversation.id and
         message.discord_message_id == nil and
         DateTime.compare(message.inserted_at, conversation.started_at) in [:gt, :eq],
       do: {:ok, changeset},
       else: {:error, :invalid_message}
  end

  defp validate_capacity(%ConversationRecord{
         turn_count: turn_count,
         llm_call_count: llm_call_count
       })
       when turn_count < @max_safe_integer and llm_call_count < @max_safe_integer,
       do: :ok

  defp validate_capacity(_conversation), do: {:error, :conversation_limit}

  defp persist(conversation, changeset) do
    case Repo.transaction(fn -> append_transaction(conversation, changeset) end) do
      {:ok, {%MessageRecord{}, %ConversationRecord{}} = result} ->
        {:ok, result}

      {:error, reason}
      when reason in [
             :conversation_conflict,
             :invalid_conversation_record,
             :invalid_message_record,
             :message_conflict
           ] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp append_transaction(conversation, changeset) do
    with :ok <- require_ordered_history(conversation.id, changeset),
         :ok <- advance_conversation(conversation),
         {:ok, message_record} <- insert_message(changeset),
         {:ok, conversation_record} <- restore_advanced_conversation(conversation) do
      {message_record, conversation_record}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp require_ordered_history(conversation_id, changeset) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    case Repo.one(latest_message_query(conversation_id)) do
      nil ->
        :ok

      %MessageRecord{} = latest ->
        if MessageRecordValidator.validate(latest) == :ok and
             DateTime.compare(candidate.inserted_at, latest.inserted_at) in [:gt, :eq],
           do: :ok,
           else: {:error, classify_latest_error(latest, candidate)}
    end
  end

  defp classify_latest_error(latest, candidate) do
    if MessageRecordValidator.validate(latest) == :ok and
         DateTime.compare(candidate.inserted_at, latest.inserted_at) == :lt,
       do: :message_conflict,
       else: :invalid_message_record
  end

  defp latest_message_query(conversation_id) do
    from record in MessageRecord,
      where: record.conversation_id == ^conversation_id,
      order_by: [desc: record.inserted_at, desc: record.id],
      limit: 1
  end

  defp advance_conversation(conversation) do
    query =
      from persisted in ConversationRecord,
        where:
          persisted.id == ^conversation.id and
            persisted.root_event_id == ^conversation.root_event_id and
            persisted.status == ^conversation.status and
            persisted.turn_count == ^conversation.turn_count and
            persisted.llm_call_count == ^conversation.llm_call_count and
            persisted.started_at == ^conversation.started_at and
            is_nil(persisted.completed_at)

    case Repo.update_all(query,
           set: [
             turn_count: conversation.turn_count + 1,
             llm_call_count: conversation.llm_call_count + 1
           ]
         ) do
      {1, nil} -> :ok
      {0, nil} -> {:error, :conversation_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp insert_message(changeset) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    case Repo.insert(changeset) do
      {:ok, %MessageRecord{id: id}} ->
        restore_inserted_message(id, candidate)

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp restore_inserted_message(id, candidate) do
    case Repo.get(MessageRecord, id) do
      %MessageRecord{} = persisted ->
        if Map.take(persisted, @message_fields) == Map.take(candidate, @message_fields) and
             MessageRecordValidator.validate(persisted) == :ok,
           do: {:ok, persisted},
           else: {:error, :invalid_message_record}

      nil ->
        {:error, :invalid_message_record}
    end
  end

  defp restore_advanced_conversation(previous) do
    case Repo.get(ConversationRecord, previous.id) do
      %ConversationRecord{} = record ->
        if record.id == previous.id and
             record.root_event_id == previous.root_event_id and
             record.status == previous.status and
             record.turn_count == previous.turn_count + 1 and
             record.llm_call_count == previous.llm_call_count + 1 and
             record.started_at == previous.started_at and
             record.completed_at == previous.completed_at and
             ConversationRecordValidator.validate_active(record) == :ok,
           do: {:ok, record},
           else: {:error, :invalid_conversation_record}

      nil ->
        {:error, :storage_unavailable}
    end
  end

  defp persist_publication(record, discord_message_id) do
    case Repo.transaction(fn -> publication_transaction(record, discord_message_id) end) do
      {:ok, %MessageRecord{} = published} ->
        {:ok, published}

      {:error, reason} when reason in [:invalid_message_record, :publication_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp publication_transaction(record, discord_message_id) do
    with {:ok, persisted} <- restore_exact_unpublished(record),
         :ok <- update_publication_id(persisted, discord_message_id),
         {:ok, published} <- restore_published(persisted, discord_message_id) do
      published
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp restore_exact_unpublished(expected) do
    case Repo.get(MessageRecord, expected.id) do
      %MessageRecord{} = persisted ->
        cond do
          MessageRecordValidator.validate(persisted) != :ok ->
            {:error, :invalid_message_record}

          persisted.discord_message_id != nil ->
            {:error, :publication_conflict}

          Map.take(persisted, [:id | @message_fields]) !=
              Map.take(expected, [:id | @message_fields]) ->
            {:error, :publication_conflict}

          true ->
            {:ok, persisted}
        end

      nil ->
        {:error, :publication_conflict}
    end
  end

  defp update_publication_id(persisted, discord_message_id) do
    changeset =
      persisted
      |> change(discord_message_id: discord_message_id)
      |> unique_constraint(:discord_message_id)

    case Repo.update(changeset) do
      {:ok, %MessageRecord{}} ->
        :ok

      {:error, %Ecto.Changeset{} = failed} ->
        if Keyword.has_key?(failed.errors, :discord_message_id),
          do: {:error, :publication_conflict},
          else: {:error, :storage_unavailable}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp restore_published(previous, discord_message_id) do
    expected = %{previous | discord_message_id: discord_message_id}

    case Repo.get(MessageRecord, previous.id) do
      %MessageRecord{} = published ->
        if Map.take(published, [:id | @message_fields]) ==
             Map.take(expected, [:id | @message_fields]) and
             MessageRecordValidator.validate(published) == :ok,
           do: {:ok, published},
           else: {:error, :invalid_message_record}

      nil ->
        {:error, :invalid_message_record}
    end
  end

  defp read_conversation_history(conversation) do
    case Repo.transaction(fn -> conversation_history_transaction(conversation) end) do
      {:ok, messages} when is_list(messages) ->
        {:ok, messages}

      {:error, reason}
      when reason in [
             :conversation_conflict,
             :invalid_conversation_record,
             :invalid_message_record
           ] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp conversation_history_transaction(expected) do
    with {:ok, conversation} <- restore_exact_conversation(expected),
         :ok <- validate_message_count(conversation),
         {:ok, messages} <- load_conversation_messages(conversation) do
      messages
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp restore_exact_conversation(expected) do
    case Repo.get(ConversationRecord, expected.id) do
      %ConversationRecord{} = persisted ->
        cond do
          ConversationRecordValidator.validate(persisted) != :ok ->
            {:error, :invalid_conversation_record}

          Map.take(persisted, @conversation_fields) !=
              Map.take(expected, @conversation_fields) ->
            {:error, :conversation_conflict}

          true ->
            {:ok, persisted}
        end

      nil ->
        {:error, :conversation_conflict}
    end
  end

  defp validate_message_count(conversation) do
    total =
      Repo.aggregate(
        from(record in MessageRecord,
          where: record.conversation_id == ^conversation.id
        ),
        :count
      )

    if total == conversation.turn_count and
         conversation.llm_call_count >= conversation.turn_count,
       do: :ok,
       else: {:error, :invalid_conversation_record}
  end

  defp load_conversation_messages(conversation) do
    records =
      conversation.id
      |> conversation_history_query()
      |> Repo.all()
      |> Enum.reverse()

    if valid_conversation_history?(
         records,
         conversation.id,
         conversation.started_at,
         conversation.completed_at
       ),
       do: {:ok, Enum.map(records, &project_message/1)},
       else: {:error, :invalid_message_record}
  end

  defp conversation_history_query(conversation_id) do
    from record in MessageRecord,
      where: record.conversation_id == ^conversation_id,
      order_by: [desc: record.inserted_at, desc: record.id],
      limit: @max_conversation_messages
  end

  defp valid_conversation_history?(records, conversation_id, started_at, completed_at) do
    result =
      Enum.reduce_while(records, {:ok, started_at}, fn record, {:ok, previous_at} ->
        if MessageRecordValidator.validate(record) == :ok and
             record.conversation_id == conversation_id and
             DateTime.compare(record.inserted_at, previous_at) in [:gt, :eq] and
             within_completion?(record.inserted_at, completed_at),
           do: {:cont, {:ok, record.inserted_at}},
           else: {:halt, :error}
      end)

    match?({:ok, _last_message_at}, result)
  end

  defp within_completion?(_inserted_at, nil), do: true

  defp within_completion?(inserted_at, completed_at),
    do: DateTime.compare(inserted_at, completed_at) in [:lt, :eq]

  defp project_message(record) do
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

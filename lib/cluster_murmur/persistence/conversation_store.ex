defmodule ClusterMurmur.Persistence.ConversationStore do
  @moduledoc """
  Atomically starts bounded conversations through a narrow persistence API.

  A start requires one validated committed root event and a new conversation
  ID. The store does not select participants, generate messages, or continue a
  conversation.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.{DateTimeValidator, DomainLimits}
  alias ClusterMurmur.Config.Value

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    EventStore,
    MessageStore,
    ResponderGenerationClaim
  }

  alias ClusterMurmur.Repo

  @persisted_fields [
    :id,
    :root_event_id,
    :status,
    :turn_count,
    :llm_call_count,
    :started_at,
    :completed_at
  ]
  @generation_claim_fields [:conversation_id, :persona_id, :turn_count, :llm_call_count]
  @max_incomplete_conversations 100
  @max_safe_integer DomainLimits.max_safe_integer()

  @type error ::
          :conversation_conflict
          | :event_not_found
          | :invalid_conversation
          | :invalid_conversation_record
          | :invalid_datetime
          | :invalid_message_record
          | :invalid_persona_id
          | :storage_unavailable

  @doc "Starts one pristine conversation for an existing validated event."
  @spec start(term()) :: {:ok, ConversationRecord.t()} | {:error, error()}
  def start(conversation) do
    changeset = ConversationRecord.start_changeset(%ConversationRecord{}, conversation)

    if changeset.valid? do
      persist_start(changeset)
    else
      {:error, :invalid_conversation}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Marks one exact active conversation completed at the supplied UTC instant."
  @spec complete(term(), term()) :: {:ok, ConversationRecord.t()} | {:error, error()}
  def complete(record, completed_at), do: finish(record, :completed, completed_at)

  @doc "Marks one exact active conversation cancelled at the supplied UTC instant."
  @spec cancel(term(), term()) :: {:ok, ConversationRecord.t()} | {:error, error()}
  def cancel(record, completed_at), do: finish(record, :cancelled, completed_at)

  @doc "Marks one exact active conversation failed at the supplied UTC instant."
  @spec fail(term(), term()) :: {:ok, ConversationRecord.t()} | {:error, error()}
  def fail(record, completed_at), do: finish(record, :failed, completed_at)

  @doc "Moves one exact starting or generating conversation into its waiting state."
  @spec wait(term()) :: {:ok, ConversationRecord.t()} | {:error, error()}
  def wait(record) do
    with :ok <- ConversationRecordValidator.validate_active(record),
         true <- record.status in [:starting, :generating] do
      persist_waiting(record)
    else
      false -> {:error, :conversation_conflict}
      {:error, :invalid_conversation_record} -> {:error, :invalid_conversation_record}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Claims one exact waiting conversation for a single generation attempt."
  @spec claim_generation(term(), term()) :: {:ok, ConversationRecord.t()} | {:error, error()}
  def claim_generation(record, persona_id) do
    with :ok <- ConversationRecordValidator.validate_active(record),
         {:ok, _persona_id} <- Value.id(persona_id),
         true <- record.status == :waiting,
         true <- record.turn_count == record.llm_call_count,
         true <- record.llm_call_count < @max_safe_integer do
      persist_generation_claim(record, persona_id)
    else
      false -> {:error, :conversation_conflict}
      {:error, :invalid_conversation_record} -> {:error, :invalid_conversation_record}
      {:error, :invalid_id} -> {:error, :invalid_persona_id}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Consumes the exact durable responder selection before provider I/O."
  @spec consume_generation(term(), term()) :: :ok | {:error, error()}
  def consume_generation(record, persona_id) do
    with :ok <- ConversationRecordValidator.validate_active(record),
         {:ok, _persona_id} <- Value.id(persona_id),
         true <- record.status == :generating do
      case Repo.transaction(fn -> consume_generation_transaction(record, persona_id) end) do
        {:ok, :ok} -> :ok
        {:error, :conversation_conflict} -> {:error, :conversation_conflict}
        _failure -> {:error, :storage_unavailable}
      end
    else
      false -> {:error, :conversation_conflict}
      {:error, :invalid_id} -> {:error, :invalid_persona_id}
      _failure -> {:error, :invalid_conversation_record}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp consume_generation_transaction(record, persona_id) do
    conversation_query =
      from persisted in ConversationRecord,
        where:
          persisted.id == ^record.id and persisted.root_event_id == ^record.root_event_id and
            persisted.status == :generating and persisted.turn_count == ^record.turn_count and
            persisted.llm_call_count == ^record.llm_call_count and
            persisted.started_at == ^record.started_at and is_nil(persisted.completed_at)

    claim_query =
      from claim in ResponderGenerationClaim,
        where:
          claim.conversation_id == ^record.id and claim.persona_id == ^persona_id and
            claim.turn_count == ^record.turn_count and
            claim.llm_call_count == ^record.llm_call_count

    with {1, nil} <- Repo.update_all(conversation_query, set: [status: :generating]),
         {1, nil} <- Repo.delete_all(claim_query) do
      :ok
    else
      _failure -> Repo.rollback(:conversation_conflict)
    end
  end

  @doc "Confirms that one exact completed capability remains authoritative."
  @spec confirm_completed(term()) :: :ok | {:error, error()}
  def confirm_completed(record) do
    with :ok <- ConversationRecordValidator.validate(record),
         true <- record.status == :completed do
      case Repo.get(ConversationRecord, record.id) do
        ^record -> :ok
        _missing_or_changed -> {:error, :conversation_conflict}
      end
    else
      false -> {:error, :conversation_conflict}
      _failure -> {:error, :invalid_conversation_record}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Lists at most 100 active conversations started at or before one UTC cutoff."
  @spec list_active_before(term()) ::
          {:ok, [ConversationRecord.t()]}
          | {:error, :invalid_datetime | :invalid_conversation_record | :storage_unavailable}
  def list_active_before(cutoff) do
    if DateTimeValidator.validate_storage_utc(cutoff) == :ok do
      records = Repo.all(active_before_query(cutoff))

      if Enum.all?(records, &(ConversationRecordValidator.validate_active(&1) == :ok)),
        do: {:ok, records},
        else: {:error, :invalid_conversation_record}
    else
      {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp persist_start(changeset) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    case Repo.transaction(fn -> start_transaction(candidate) end) do
      {:ok, %ConversationRecord{} = record} ->
        {:ok, record}

      {:error, reason} when reason in [:conversation_conflict, :event_not_found] ->
        {:error, reason}

      {:error, :invalid_conversation_record} ->
        {:error, :invalid_conversation_record}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp active_before_query(cutoff) do
    from record in ConversationRecord,
      where:
        fragment("? IN ('starting', 'generating', 'waiting')", record.status) and
          record.started_at <= ^cutoff,
      order_by: [asc: record.started_at, asc: record.id],
      limit: @max_incomplete_conversations
  end

  defp start_transaction(candidate) do
    with :ok <- require_root_event(candidate.root_event_id),
         :ok <- insert_once(candidate),
         {:ok, record} <- restore_started(candidate.id) do
      record
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp require_root_event(event_id) do
    case EventStore.fetch(event_id) do
      {:ok, _event} -> :ok
      {:error, :event_not_found} -> {:error, :event_not_found}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp insert_once(candidate) do
    attributes = Map.take(candidate, @persisted_fields)

    case Repo.insert_all(ConversationRecord, [attributes],
           on_conflict: :nothing,
           conflict_target: [:id]
         ) do
      {1, nil} -> :ok
      {0, nil} -> {:error, :conversation_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp restore_started(id) do
    case Repo.get(ConversationRecord, id) do
      %ConversationRecord{} = record ->
        if ConversationRecordValidator.validate_started(record) == :ok,
          do: {:ok, record},
          else: {:error, :invalid_conversation_record}

      nil ->
        {:error, :storage_unavailable}
    end
  end

  defp finish(record, status, completed_at) do
    with :ok <- ConversationRecordValidator.validate_active(record),
         :ok <- validate_completion(completed_at, record.started_at),
         :ok <- validate_terminal_history(record, completed_at) do
      persist_terminal(record, status, completed_at)
    else
      {:error, :conversation_conflict} -> {:error, :conversation_conflict}
      {:error, :invalid_conversation_record} -> {:error, :invalid_conversation_record}
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      {:error, :invalid_message_record} -> {:error, :invalid_message_record}
      {:error, :storage_unavailable} -> {:error, :storage_unavailable}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp validate_terminal_history(record, completed_at) do
    case MessageStore.list_for_conversation(record) do
      {:ok, []} ->
        :ok

      {:ok, messages} ->
        if DateTime.compare(List.last(messages).inserted_at, completed_at) in [:lt, :eq],
          do: :ok,
          else: {:error, :invalid_datetime}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_completion(completed_at, started_at) do
    if DateTimeValidator.validate_storage_utc(completed_at) == :ok and
         DateTime.compare(completed_at, started_at) in [:gt, :eq],
       do: :ok,
       else: {:error, :invalid_datetime}
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  defp persist_terminal(record, status, completed_at) do
    case Repo.transaction(fn -> compare_and_set_terminal(record, status, completed_at) end) do
      {:ok, %ConversationRecord{} = terminal} -> {:ok, terminal}
      {:error, :conversation_conflict} -> {:error, :conversation_conflict}
      {:error, :invalid_conversation_record} -> {:error, :invalid_conversation_record}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp persist_waiting(record) do
    case Repo.transaction(fn -> compare_and_set_waiting(record) end) do
      {:ok, %ConversationRecord{} = waiting} -> {:ok, waiting}
      {:error, :conversation_conflict} -> {:error, :conversation_conflict}
      {:error, :invalid_conversation_record} -> {:error, :invalid_conversation_record}
      {:error, :invalid_message_record} -> {:error, :invalid_message_record}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp persist_generation_claim(record, persona_id) do
    case Repo.transaction(fn -> compare_and_set_generation(record, persona_id) end) do
      {:ok, %ConversationRecord{} = generating} -> {:ok, generating}
      {:error, :conversation_conflict} -> {:error, :conversation_conflict}
      {:error, :invalid_conversation_record} -> {:error, :invalid_conversation_record}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp compare_and_set_waiting(record) do
    query =
      from persisted in ConversationRecord,
        where:
          persisted.id == ^record.id and
            persisted.root_event_id == ^record.root_event_id and
            persisted.status == ^record.status and
            persisted.turn_count == ^record.turn_count and
            persisted.llm_call_count == ^record.llm_call_count and
            persisted.started_at == ^record.started_at and
            is_nil(persisted.completed_at)

    with :ok <- require_waitable_generation(record) do
      case Repo.update_all(query, set: [status: :waiting]) do
        {1, nil} ->
          restore_waiting(record)

        {0, nil} ->
          Repo.rollback(:conversation_conflict)

        _failure ->
          Repo.rollback(:storage_unavailable)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp require_waitable_generation(%ConversationRecord{status: :starting}), do: :ok

  defp require_waitable_generation(%ConversationRecord{status: :generating} = record) do
    query =
      from claim in ResponderGenerationClaim,
        where: claim.conversation_id == ^record.id

    with 0 <- Repo.aggregate(query, :count),
         true <- record.turn_count == record.llm_call_count,
         {:ok, _messages} <- MessageStore.list_for_conversation(record) do
      :ok
    else
      outstanding when is_integer(outstanding) -> {:error, :conversation_conflict}
      false -> {:error, :conversation_conflict}
      {:error, reason} -> {:error, reason}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp compare_and_set_generation(record, persona_id) do
    query =
      from persisted in ConversationRecord,
        where:
          persisted.id == ^record.id and
            persisted.root_event_id == ^record.root_event_id and
            persisted.status == :waiting and
            persisted.turn_count == ^record.turn_count and
            persisted.llm_call_count == ^record.llm_call_count and
            persisted.started_at == ^record.started_at and
            is_nil(persisted.completed_at)

    case Repo.update_all(query,
           set: [status: :generating, llm_call_count: record.llm_call_count + 1]
         ) do
      {1, nil} ->
        with {:ok, expected_claim} <- insert_generation_claim(record, persona_id),
             %ConversationRecord{} = generating <- restore_generation_claim(record),
             :ok <- restore_inserted_generation_claim(expected_claim) do
          generating
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      {0, nil} ->
        Repo.rollback(:conversation_conflict)

      _failure ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp insert_generation_claim(record, persona_id) do
    claim = %{
      conversation_id: record.id,
      persona_id: persona_id,
      turn_count: record.turn_count,
      llm_call_count: record.llm_call_count + 1
    }

    case Repo.insert_all(ResponderGenerationClaim, [claim],
           on_conflict: :nothing,
           conflict_target: [:conversation_id]
         ) do
      {1, nil} -> {:ok, claim}
      {0, nil} -> {:error, :conversation_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp restore_inserted_generation_claim(expected) do
    case Repo.get(ResponderGenerationClaim, expected.conversation_id) do
      %ResponderGenerationClaim{} = persisted ->
        if Map.take(persisted, @generation_claim_fields) == expected,
          do: :ok,
          else: {:error, :conversation_conflict}

      nil ->
        {:error, :conversation_conflict}
    end
  end

  defp restore_waiting(previous) do
    case Repo.get(ConversationRecord, previous.id) do
      %ConversationRecord{} = waiting ->
        expected = %{previous | status: :waiting}

        if waiting === expected and ConversationRecordValidator.validate_active(waiting) == :ok,
          do: waiting,
          else: Repo.rollback(:invalid_conversation_record)

      nil ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp restore_generation_claim(previous) do
    case Repo.get(ConversationRecord, previous.id) do
      %ConversationRecord{} = generating ->
        expected = %{
          previous
          | status: :generating,
            llm_call_count: previous.llm_call_count + 1
        }

        if generating === expected and
             ConversationRecordValidator.validate_active(generating) == :ok,
           do: generating,
           else: Repo.rollback(:invalid_conversation_record)

      nil ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp compare_and_set_terminal(record, status, completed_at) do
    query =
      from persisted in ConversationRecord,
        where:
          persisted.id == ^record.id and
            persisted.root_event_id == ^record.root_event_id and
            persisted.status == ^record.status and
            persisted.turn_count == ^record.turn_count and
            persisted.llm_call_count == ^record.llm_call_count and
            persisted.started_at == ^record.started_at and
            is_nil(persisted.completed_at)

    case Repo.update_all(query, set: [status: status, completed_at: completed_at]) do
      {1, nil} ->
        with :ok <- discard_generation_claim(record) do
          restore_terminal(record.id, status, completed_at)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      {0, nil} ->
        Repo.rollback(:conversation_conflict)

      _failure ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp discard_generation_claim(%ConversationRecord{status: status})
       when status in [:starting, :waiting],
       do: :ok

  defp discard_generation_claim(%ConversationRecord{status: :generating} = record) do
    query =
      from claim in ResponderGenerationClaim,
        where: claim.conversation_id == ^record.id

    case Repo.delete_all(query) do
      {count, nil} when count in 0..1 -> :ok
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp restore_terminal(id, status, completed_at) do
    case Repo.get(ConversationRecord, id) do
      %ConversationRecord{} = terminal ->
        if terminal.status == status and
             DateTime.compare(terminal.completed_at, completed_at) == :eq and
             ConversationRecordValidator.validate(terminal) == :ok,
           do: terminal,
           else: Repo.rollback(:invalid_conversation_record)

      nil ->
        Repo.rollback(:storage_unavailable)
    end
  end
end

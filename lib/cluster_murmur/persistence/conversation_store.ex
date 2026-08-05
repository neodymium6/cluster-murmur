defmodule ClusterMurmur.Persistence.ConversationStore do
  @moduledoc """
  Atomically starts bounded conversations through a narrow persistence API.

  A start requires one validated committed root event and a new conversation
  ID. The store does not select participants, generate messages, or continue a
  conversation.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    EventStore
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

  @type error ::
          :conversation_conflict
          | :event_not_found
          | :invalid_conversation
          | :invalid_conversation_record
          | :invalid_datetime
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
         :ok <- validate_completion(completed_at, record.started_at) do
      persist_terminal(record, status, completed_at)
    else
      {:error, :invalid_conversation_record} -> {:error, :invalid_conversation_record}
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
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
      {1, nil} -> restore_terminal(record.id, status, completed_at)
      {0, nil} -> Repo.rollback(:conversation_conflict)
      _failure -> Repo.rollback(:storage_unavailable)
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

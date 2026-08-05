defmodule ClusterMurmur.Persistence.ConversationStore do
  @moduledoc """
  Atomically starts bounded conversations through a narrow persistence API.

  A start requires one validated committed root event and a new conversation
  ID. The store does not select participants, generate messages, or continue a
  conversation.
  """

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
end

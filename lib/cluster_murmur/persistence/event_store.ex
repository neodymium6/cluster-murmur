defmodule ClusterMurmur.Persistence.EventStore do
  @moduledoc """
  Persists immutable bounded events through one idempotent store operation.

  Repeating the exact event returns the committed redacted record. Reusing an
  event ID for different content is a stable conflict and never replaces the
  first committed fact.
  """

  alias ClusterMurmur.Persistence.EventRecord
  alias ClusterMurmur.Repo

  @event_fields [
    :id,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :previous,
    :current,
    :dedupe_key,
    :correlation_key,
    :facts,
    :labels,
    :occurred_at,
    :observed_at
  ]

  @type error :: :event_conflict | :invalid_event | :storage_unavailable

  @doc "Inserts one event or restores the identical record already committed for its ID."
  @spec insert(term()) :: {:ok, EventRecord.t()} | {:error, error()}
  def insert(event) do
    changeset = EventRecord.changeset(%EventRecord{}, event)

    if changeset.valid? do
      persist(changeset)
    else
      {:error, :invalid_event}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp persist(changeset) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    case Repo.transaction(fn -> insert_then_restore(changeset, candidate) end) do
      {:ok, %EventRecord{} = record} -> {:ok, record}
      {:error, :event_conflict} -> {:error, :event_conflict}
      {:error, :invalid_event} -> {:error, :invalid_event}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp insert_then_restore(changeset, candidate) do
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:id]) do
      {:ok, _inserted_or_conflicted} -> restore_identical(candidate)
      {:error, _changeset} -> Repo.rollback(:invalid_event)
    end
  end

  defp restore_identical(candidate) do
    case Repo.get(EventRecord, candidate.id) do
      %EventRecord{} = persisted ->
        if identical_event?(persisted, candidate),
          do: persisted,
          else: Repo.rollback(:event_conflict)

      nil ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp identical_event?(persisted, candidate) do
    Map.take(persisted, @event_fields) == Map.take(candidate, @event_fields)
  end
end

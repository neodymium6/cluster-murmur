defmodule ClusterMurmur.Persistence.EntityStateStore do
  @moduledoc """
  Restores and monotonically replaces bounded observation entity state.

  The store accepts already-decided debounce state. It does not observe a
  target, derive a transition, emit an event, or expose generic repository
  access.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Events.Validator
  alias ClusterMurmur.Observations.EntityState

  alias ClusterMurmur.Persistence.{
    EntityStateRecord,
    EntityStateRecordValidator
  }

  alias ClusterMurmur.Repo

  @fields [
    :source,
    :subject,
    :current_state,
    :pending_state,
    :consecutive_count,
    :last_observed_at,
    :last_changed_at,
    :facts,
    :labels
  ]

  @type error ::
          :entity_state_conflict
          | :invalid_entity_identity
          | :invalid_entity_state
          | :invalid_entity_state_record
          | :storage_unavailable

  @doc "Restores validated state for one complete source and subject identity."
  @spec fetch(term(), term()) :: {:ok, EntityState.t() | nil} | {:error, error()}
  def fetch(source, subject) do
    if valid_identity?(source, subject) do
      case restore_record(source, subject) do
        nil -> {:ok, nil}
        %EntityStateRecord{} = record -> EntityStateRecordValidator.decode(record)
      end
    else
      {:error, :invalid_entity_identity}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Persists a newer state, treating only an exact equal-time retry as idempotent."
  @spec put(term()) :: {:ok, EntityStateRecord.t()} | {:error, error()}
  def put(state) do
    changeset = EntityStateRecord.changeset(%EntityStateRecord{}, state)

    if changeset.valid? do
      changeset |> Ecto.Changeset.apply_changes() |> persist()
    else
      {:error, :invalid_entity_state}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp valid_identity?(source, subject),
    do: Validator.validate_id(source) == :ok and Validator.validate_id(subject) == :ok

  defp persist(candidate) do
    case Repo.transaction(fn -> put_transaction(candidate) end) do
      {:ok, %EntityStateRecord{} = record} ->
        {:ok, record}

      {:error, reason}
      when reason in [:entity_state_conflict, :invalid_entity_state_record] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp put_transaction(candidate) do
    case restore_record(candidate.source, candidate.subject) do
      nil -> insert_candidate(candidate)
      %EntityStateRecord{} = persisted -> advance_candidate(persisted, candidate)
    end
  end

  defp insert_candidate(candidate) do
    case Repo.insert_all(EntityStateRecord, [Map.take(candidate, @fields)],
           on_conflict: :nothing,
           conflict_target: [:source, :subject]
         ) do
      {count, nil} when count in [0, 1] -> restore_candidate(candidate)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp advance_candidate(persisted, candidate),
    do: advance_candidate(persisted, candidate, true)

  defp advance_candidate(persisted, candidate, retry?) do
    if EntityStateRecordValidator.validate(persisted) == :ok do
      case DateTime.compare(candidate.last_observed_at, persisted.last_observed_at) do
        :lt -> Repo.rollback(:entity_state_conflict)
        :eq -> exact_or_conflict(persisted, candidate)
        :gt -> compare_and_set(persisted, candidate, retry?)
      end
    else
      Repo.rollback(:invalid_entity_state_record)
    end
  end

  defp exact_or_conflict(persisted, candidate) do
    if same_facts?(persisted, candidate),
      do: persisted,
      else: Repo.rollback(:entity_state_conflict)
  end

  defp compare_and_set(persisted, candidate, retry?) do
    query =
      from record in EntityStateRecord,
        where:
          record.source == ^persisted.source and record.subject == ^persisted.subject and
            record.last_observed_at == ^persisted.last_observed_at

    updates =
      candidate
      |> Map.take(@fields)
      |> Map.drop([:source, :subject])
      |> Map.to_list()

    case Repo.update_all(query, set: updates) do
      {1, nil} -> restore_candidate(candidate)
      {0, nil} when retry? -> retry_candidate(candidate)
      {0, nil} -> restore_candidate(candidate)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp retry_candidate(candidate) do
    case restore_record(candidate.source, candidate.subject) do
      %EntityStateRecord{} = persisted -> advance_candidate(persisted, candidate, false)
      nil -> Repo.rollback(:entity_state_conflict)
    end
  end

  defp restore_candidate(candidate) do
    case restore_record(candidate.source, candidate.subject) do
      %EntityStateRecord{} = persisted ->
        cond do
          EntityStateRecordValidator.validate(persisted) != :ok ->
            Repo.rollback(:invalid_entity_state_record)

          same_facts?(persisted, candidate) ->
            persisted

          true ->
            Repo.rollback(:entity_state_conflict)
        end

      nil ->
        Repo.rollback(:entity_state_conflict)
    end
  end

  defp restore_record(source, subject),
    do: Repo.get_by(EntityStateRecord, source: source, subject: subject)

  defp same_facts?(left, right), do: Map.take(left, @fields) == Map.take(right, @fields)
end

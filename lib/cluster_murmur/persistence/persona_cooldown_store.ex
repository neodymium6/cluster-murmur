defmodule ClusterMurmur.Persistence.PersonaCooldownStore do
  @moduledoc """
  Restores and monotonically records bounded persona selection cooldowns.

  The store accepts only explicit persona and timing facts. It does not read a
  clock, load persona configuration, derive cooldown policy, select a speaker,
  or expose generic repository access.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DomainLimits

  alias ClusterMurmur.Persistence.{
    PersonaCooldownRecord,
    PersonaCooldownRecordValidator
  }

  alias ClusterMurmur.Repo

  @fields [:persona_id, :cooldown_until, :last_spoken_at]
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()

  @type error ::
          :invalid_persona_cooldown
          | :invalid_persona_cooldown_record
          | :invalid_persona_id
          | :persona_cooldown_conflict
          | :storage_unavailable

  @doc "Restores the validated cooldown for one bounded persona ID, if present."
  @spec fetch(term()) :: {:ok, PersonaCooldownRecord.t() | nil} | {:error, error()}
  def fetch(persona_id) do
    if valid_persona_id?(persona_id) do
      restore(persona_id)
    else
      {:error, :invalid_persona_id}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Records one latest spoken instant and its bounded cooldown deadline."
  @spec record_spoken(term(), term(), term()) ::
          {:ok, PersonaCooldownRecord.t()} | {:error, error()}
  def record_spoken(persona_id, last_spoken_at, cooldown_until) do
    changeset =
      PersonaCooldownRecord.changeset(
        %PersonaCooldownRecord{},
        persona_id,
        last_spoken_at,
        cooldown_until
      )

    if changeset.valid? do
      changeset |> Ecto.Changeset.apply_changes() |> persist()
    else
      {:error, :invalid_persona_cooldown}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp valid_persona_id?(persona_id)
       when is_binary(persona_id) and byte_size(persona_id) in 1..@max_id_bytes do
    String.valid?(persona_id) and Regex.match?(@id_pattern, persona_id)
  end

  defp valid_persona_id?(_persona_id), do: false

  defp restore(persona_id) do
    case Repo.get(PersonaCooldownRecord, persona_id) do
      nil ->
        {:ok, nil}

      %PersonaCooldownRecord{} = record ->
        if PersonaCooldownRecordValidator.validate(record) == :ok,
          do: {:ok, record},
          else: {:error, :invalid_persona_cooldown_record}
    end
  end

  defp persist(candidate) do
    case Repo.transaction(fn -> record_transaction(candidate) end) do
      {:ok, %PersonaCooldownRecord{} = record} ->
        {:ok, record}

      {:error, reason}
      when reason in [:invalid_persona_cooldown_record, :persona_cooldown_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp record_transaction(candidate) do
    case Repo.get(PersonaCooldownRecord, candidate.persona_id) do
      nil ->
        insert_candidate(candidate)

      %PersonaCooldownRecord{} = persisted ->
        advance_candidate(persisted, candidate)
    end
  end

  defp insert_candidate(candidate) do
    attributes = Map.take(candidate, @fields)

    case Repo.insert_all(PersonaCooldownRecord, [attributes],
           on_conflict: :nothing,
           conflict_target: [:persona_id]
         ) do
      {count, nil} when count in [0, 1] -> restore_candidate(candidate)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp advance_candidate(persisted, candidate) do
    if PersonaCooldownRecordValidator.validate(persisted) == :ok do
      case DateTime.compare(candidate.last_spoken_at, persisted.last_spoken_at) do
        :lt ->
          Repo.rollback(:persona_cooldown_conflict)

        :eq ->
          if same_facts?(persisted, candidate),
            do: persisted,
            else: Repo.rollback(:persona_cooldown_conflict)

        :gt ->
          compare_and_set(persisted, candidate)
      end
    else
      Repo.rollback(:invalid_persona_cooldown_record)
    end
  end

  defp compare_and_set(persisted, candidate) do
    query =
      from record in PersonaCooldownRecord,
        where:
          record.persona_id == ^persisted.persona_id and
            record.last_spoken_at == ^persisted.last_spoken_at and
            record.cooldown_until == ^persisted.cooldown_until

    case Repo.update_all(query,
           set: [
             last_spoken_at: candidate.last_spoken_at,
             cooldown_until: candidate.cooldown_until
           ]
         ) do
      {1, nil} -> restore_candidate(candidate)
      {0, nil} -> restore_candidate(candidate)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp restore_candidate(candidate) do
    case Repo.get(PersonaCooldownRecord, candidate.persona_id) do
      %PersonaCooldownRecord{} = persisted ->
        cond do
          PersonaCooldownRecordValidator.validate(persisted) != :ok ->
            Repo.rollback(:invalid_persona_cooldown_record)

          same_facts?(persisted, candidate) ->
            persisted

          true ->
            Repo.rollback(:persona_cooldown_conflict)
        end

      nil ->
        Repo.rollback(:persona_cooldown_conflict)
    end
  end

  defp same_facts?(left, right),
    do: Map.take(left, @fields) == Map.take(right, @fields)
end

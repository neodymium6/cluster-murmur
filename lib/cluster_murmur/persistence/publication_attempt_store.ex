defmodule ClusterMurmur.Persistence.PublicationAttemptStore do
  @moduledoc """
  Restores and starts durable Discord publication attempts through a narrow API.

  Start rechecks the independently loaded current message inside the immediate
  transaction. It never calls Discord or performs terminal transitions.
  """

  alias ClusterMurmur.{DateTimeValidator, Repo}
  alias ClusterMurmur.Discord.PublicationPlanValidator

  alias ClusterMurmur.Persistence.{
    MessageRecord,
    MessageRecordValidator,
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator
  }

  @fields [:message_id, :status, :started_at, :completed_at, :error_class]
  @max_sqlite_integer 9_223_372_036_854_775_807

  @type error ::
          :invalid_datetime
          | :invalid_message_id
          | :invalid_message_record
          | :invalid_publication_attempt_record
          | :invalid_publication_plan
          | :publication_attempt_conflict
          | :publication_conflict
          | :storage_unavailable

  @doc "Restores one exact validated attempt by its durable message ID."
  @spec fetch(term()) :: {:ok, PublicationAttemptRecord.t() | nil} | {:error, error()}
  def fetch(message_id) do
    if valid_message_id?(message_id) do
      case Repo.get_by(PublicationAttemptRecord, message_id: message_id) do
        nil -> {:ok, nil}
        %PublicationAttemptRecord{} = attempt -> validate_attempt(attempt)
      end
    else
      {:error, :invalid_message_id}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Starts one exact current publication plan before any external request."
  @spec start(term(), term(), term(), term(), term()) ::
          {:ok, PublicationAttemptRecord.t()} | {:error, error()}
  def start(plan, current_record, current_persona, current_settings, started_at) do
    with :ok <-
           PublicationPlanValidator.validate(
             plan,
             current_record,
             current_persona,
             current_settings
           ),
         {:ok, started_at} <- validate_started_at(current_record, started_at),
         %{valid?: true} = changeset <-
           PublicationAttemptRecord.start_changeset(
             %PublicationAttemptRecord{},
             current_record,
             started_at
           ) do
      changeset |> Ecto.Changeset.apply_changes() |> persist_start(current_record)
    else
      {:error, :invalid_publication_plan} -> {:error, :invalid_publication_plan}
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      _failure -> {:error, :invalid_publication_attempt_record}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp validate_started_at(record, started_at) do
    if DateTimeValidator.validate_storage_utc(started_at) == :ok and
         DateTime.compare(started_at, record.inserted_at) in [:gt, :eq],
       do: {:ok, normalize_microsecond_precision(started_at)},
       else: {:error, :invalid_datetime}
  end

  defp normalize_microsecond_precision(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  defp persist_start(candidate, current_record) do
    case Repo.transaction(fn -> start_transaction(candidate, current_record) end) do
      {:ok, %PublicationAttemptRecord{} = attempt} ->
        {:ok, attempt}

      {:error, reason}
      when reason in [
             :invalid_message_record,
             :invalid_publication_attempt_record,
             :publication_attempt_conflict,
             :publication_conflict
           ] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp start_transaction(candidate, current_record) do
    with :ok <- restore_current_message(current_record) do
      case Repo.get_by(PublicationAttemptRecord, message_id: candidate.message_id) do
        nil -> insert_candidate(candidate)
        %PublicationAttemptRecord{} = persisted -> identical_or_conflict(persisted, candidate)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp restore_current_message(current_record) do
    case Repo.get(MessageRecord, current_record.id) do
      %MessageRecord{} = persisted ->
        cond do
          MessageRecordValidator.validate(persisted) != :ok ->
            {:error, :invalid_message_record}

          persisted != current_record or persisted.discord_message_id != nil ->
            {:error, :publication_conflict}

          true ->
            :ok
        end

      nil ->
        {:error, :publication_conflict}
    end
  end

  defp insert_candidate(candidate) do
    case Repo.insert_all(PublicationAttemptRecord, [Map.take(candidate, @fields)],
           on_conflict: :nothing,
           conflict_target: [:message_id]
         ) do
      {count, nil} when count in [0, 1] -> restore_candidate(candidate)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp identical_or_conflict(persisted, candidate) do
    if PublicationAttemptRecordValidator.validate(persisted) == :ok and
         same_facts?(persisted, candidate),
       do: persisted,
       else: Repo.rollback(classify_attempt_error(persisted))
  end

  defp restore_candidate(candidate) do
    case Repo.get_by(PublicationAttemptRecord, message_id: candidate.message_id) do
      %PublicationAttemptRecord{} = persisted -> identical_or_conflict(persisted, candidate)
      nil -> Repo.rollback(:publication_attempt_conflict)
    end
  end

  defp classify_attempt_error(persisted) do
    if PublicationAttemptRecordValidator.validate(persisted) == :ok,
      do: :publication_attempt_conflict,
      else: :invalid_publication_attempt_record
  end

  defp validate_attempt(attempt) do
    if PublicationAttemptRecordValidator.validate(attempt) == :ok,
      do: {:ok, attempt},
      else: {:error, :invalid_publication_attempt_record}
  end

  defp same_facts?(left, right), do: Map.take(left, @fields) == Map.take(right, @fields)

  defp valid_message_id?(id), do: is_integer(id) and id in 1..@max_sqlite_integer
end

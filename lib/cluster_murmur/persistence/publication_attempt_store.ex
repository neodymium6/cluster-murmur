defmodule ClusterMurmur.Persistence.PublicationAttemptStore do
  @moduledoc """
  Restores and starts durable Discord publication attempts through a narrow API.

  Start rechecks the independently loaded current message inside the immediate
  transaction. A non-idempotent compare-and-set grants one durable dispatch
  claim, and terminal transitions compare one exact open attempt. This module
  never calls Discord or stores raw external responses.
  """

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]
  import Ecto.Query

  alias ClusterMurmur.{DateTimeValidator, Repo}
  alias ClusterMurmur.Discord.PublicationPlanValidator
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  alias ClusterMurmur.Persistence.{
    MessageRecord,
    MessageRecordValidator,
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator
  }

  @fields [:message_id, :status, :started_at, :completed_at, :error_class]
  @message_fields [
    :id,
    :conversation_id,
    :persona_id,
    :origin,
    :content,
    :discord_message_id,
    :inserted_at
  ]
  @max_sqlite_integer 9_223_372_036_854_775_807
  @max_recovery_attempts 100
  @external_errors [
    :authentication_failed,
    :invalid_request,
    :invalid_response,
    :rate_limited,
    :timeout,
    :unavailable
  ]

  @type error ::
          :invalid_datetime
          | :invalid_external_error
          | :invalid_message_id
          | :invalid_message_record
          | :invalid_publication_id
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

  @doc "Claims one exact started attempt immediately before external dispatch."
  @spec claim_dispatch(term()) ::
          {:ok, PublicationAttemptRecord.t()} | {:error, error()}
  def claim_dispatch(attempt) do
    with :ok <- validate_started_attempt(attempt) do
      candidate = %{attempt | status: :dispatching}
      persist_claim(attempt, candidate)
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Closes one exact open attempt with a classified external failure."
  @spec fail(term(), term(), term()) ::
          {:ok, PublicationAttemptRecord.t()} | {:error, error()}
  def fail(attempt, error_class, completed_at),
    do: finish(attempt, :failed, error_class, completed_at)

  @doc "Closes one exact open attempt when publication outcome is unknowable."
  @spec mark_ambiguous(term(), term()) ::
          {:ok, PublicationAttemptRecord.t()} | {:error, error()}
  def mark_ambiguous(attempt, completed_at),
    do: finish(attempt, :ambiguous, :interrupted, completed_at)

  @doc "Lists at most 100 open publication attempts at or before one UTC cutoff."
  @spec list_open_before(term()) ::
          {:ok, [PublicationAttemptRecord.t()]}
          | {:error,
             :invalid_datetime | :invalid_publication_attempt_record | :storage_unavailable}
  def list_open_before(cutoff) do
    if DateTimeValidator.validate_storage_utc(cutoff) == :ok do
      query =
        from attempt in PublicationAttemptRecord,
          where: attempt.status in [:started, :dispatching] and attempt.started_at <= ^cutoff,
          order_by: [asc: attempt.started_at, asc: attempt.message_id],
          limit: @max_recovery_attempts

      attempts = Repo.all(query)

      if Enum.all?(attempts, &(PublicationAttemptRecordValidator.validate(&1) == :ok)),
        do: {:ok, attempts},
        else: {:error, :invalid_publication_attempt_record}
    else
      {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Atomically records one known Discord success for an exact dispatch claim."
  @spec succeed(term(), term(), term(), term()) ::
          {:ok, {PublicationAttemptRecord.t(), MessageRecord.t()}} | {:error, error()}
  def succeed(attempt, message, discord_message_id, completed_at) do
    with :ok <- validate_dispatching_attempt(attempt),
         :ok <- validate_success_message(attempt, message),
         :ok <- validate_publication_id(message, discord_message_id),
         {:ok, completed_at} <- validate_completed_at(attempt, completed_at) do
      succeeded = %{attempt | status: :succeeded, completed_at: completed_at, error_class: nil}
      published = %{message | discord_message_id: discord_message_id}
      persist_success(attempt, message, succeeded, published)
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

  defp finish(attempt, status, error_class, completed_at) do
    with :ok <- validate_open_attempt(attempt),
         :ok <- validate_terminal_error(status, error_class),
         {:ok, completed_at} <- validate_completed_at(attempt, completed_at) do
      candidate = %{
        attempt
        | status: status,
          completed_at: completed_at,
          error_class: error_class
      }

      persist_terminal(attempt, candidate)
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp validate_started_attempt(%PublicationAttemptRecord{status: :started} = attempt),
    do: PublicationAttemptRecordValidator.validate(attempt)

  defp validate_started_attempt(_attempt), do: {:error, :invalid_publication_attempt_record}

  defp validate_dispatching_attempt(%PublicationAttemptRecord{status: :dispatching} = attempt),
    do: PublicationAttemptRecordValidator.validate(attempt)

  defp validate_dispatching_attempt(_attempt),
    do: {:error, :invalid_publication_attempt_record}

  defp validate_open_attempt(%PublicationAttemptRecord{status: status} = attempt)
       when status in [:started, :dispatching],
       do: PublicationAttemptRecordValidator.validate(attempt)

  defp validate_open_attempt(_attempt), do: {:error, :invalid_publication_attempt_record}

  defp validate_terminal_error(:failed, error_class) when error_class in @external_errors,
    do: :ok

  defp validate_terminal_error(:ambiguous, :interrupted), do: :ok
  defp validate_terminal_error(_status, _error_class), do: {:error, :invalid_external_error}

  defp validate_success_message(attempt, %MessageRecord{} = message) do
    cond do
      MessageRecordValidator.validate(message) != :ok ->
        {:error, :invalid_message_record}

      message.discord_message_id != nil or attempt.message_id != message.id ->
        {:error, :publication_conflict}

      true ->
        :ok
    end
  end

  defp validate_success_message(_attempt, _message), do: {:error, :invalid_message_record}

  defp validate_publication_id(message, discord_message_id) when is_binary(discord_message_id) do
    candidate = %Message{
      conversation_id: message.conversation_id,
      persona_id: message.persona_id,
      origin: message.origin,
      content: message.content,
      discord_message_id: discord_message_id,
      inserted_at: message.inserted_at
    }

    if MessageValidator.validate(candidate) == :ok,
      do: :ok,
      else: {:error, :invalid_publication_id}
  end

  defp validate_publication_id(_message, _discord_message_id),
    do: {:error, :invalid_publication_id}

  defp validate_completed_at(attempt, completed_at) do
    if DateTimeValidator.validate_storage_utc(completed_at) == :ok and
         DateTime.compare(completed_at, attempt.started_at) in [:gt, :eq],
       do: {:ok, normalize_microsecond_precision(completed_at)},
       else: {:error, :invalid_datetime}
  end

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

  defp persist_terminal(started, candidate) do
    case Repo.transaction(fn -> terminal_transaction(started, candidate) end) do
      {:ok, %PublicationAttemptRecord{} = attempt} ->
        {:ok, attempt}

      {:error, reason}
      when reason in [:invalid_publication_attempt_record, :publication_attempt_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp persist_claim(started, candidate) do
    case Repo.transaction(fn -> claim_transaction(started, candidate) end) do
      {:ok, %PublicationAttemptRecord{} = attempt} ->
        {:ok, attempt}

      {:error, reason}
      when reason in [:invalid_publication_attempt_record, :publication_attempt_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp persist_success(started, unpublished, succeeded, published) do
    operation = fn -> success_transaction(started, unpublished, succeeded, published) end

    case Repo.transaction(operation) do
      {:ok, {%PublicationAttemptRecord{}, %MessageRecord{}} = result} ->
        {:ok, result}

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

  defp success_transaction(started, unpublished, succeeded, published) do
    with {:ok, durable_attempt} <- restore_attempt(started.message_id),
         {:ok, durable_message} <- restore_message(unpublished.id) do
      cond do
        same_facts?(durable_attempt, succeeded) and
            same_message_facts?(durable_message, published) ->
          {durable_attempt, durable_message}

        same_facts?(durable_attempt, started) and
            same_message_facts?(durable_message, unpublished) ->
          commit_success(started, unpublished, succeeded, published)

        not same_facts?(durable_attempt, started) ->
          Repo.rollback(:publication_attempt_conflict)

        true ->
          Repo.rollback(:publication_conflict)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp restore_attempt(message_id) do
    case Repo.get_by(PublicationAttemptRecord, message_id: message_id) do
      %PublicationAttemptRecord{} = attempt ->
        if PublicationAttemptRecordValidator.validate(attempt) == :ok,
          do: {:ok, attempt},
          else: {:error, :invalid_publication_attempt_record}

      nil ->
        {:error, :publication_attempt_conflict}
    end
  end

  defp restore_message(message_id) do
    case Repo.get(MessageRecord, message_id) do
      %MessageRecord{} = message ->
        if MessageRecordValidator.validate(message) == :ok,
          do: {:ok, message},
          else: {:error, :invalid_message_record}

      nil ->
        {:error, :publication_conflict}
    end
  end

  defp commit_success(started, unpublished, succeeded, published) do
    with :ok <- compare_and_set_message(unpublished, published.discord_message_id),
         :ok <- compare_and_set_attempt(started, succeeded),
         {:ok, durable_attempt} <- restore_attempt(started.message_id),
         {:ok, durable_message} <- restore_message(unpublished.id) do
      cond do
        not same_facts?(durable_attempt, succeeded) ->
          Repo.rollback(:publication_attempt_conflict)

        not same_message_facts?(durable_message, published) ->
          Repo.rollback(:publication_conflict)

        true ->
          {durable_attempt, durable_message}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp compare_and_set_message(message, discord_message_id) do
    changeset =
      message
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

  defp compare_and_set_attempt(started, terminal) do
    query = open_attempt_query(started)

    updates = [
      status: terminal.status,
      completed_at: terminal.completed_at,
      error_class: terminal.error_class
    ]

    case Repo.update_all(query, set: updates) do
      {1, nil} -> :ok
      {0, nil} -> {:error, :publication_attempt_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp claim_transaction(started, candidate) do
    case compare_and_set_attempt(started, candidate) do
      :ok -> restore_exact_attempt(candidate)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp terminal_transaction(started, candidate) do
    case compare_and_set_attempt(started, candidate) do
      :ok -> restore_terminal(candidate)
      {:error, :publication_attempt_conflict} -> restore_terminal(candidate)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp open_attempt_query(open) do
    from persisted in PublicationAttemptRecord,
      where:
        persisted.message_id == ^open.message_id and
          persisted.status == ^open.status and
          persisted.started_at == ^open.started_at and
          is_nil(persisted.completed_at) and
          is_nil(persisted.error_class)
  end

  defp restore_exact_attempt(candidate) do
    case Repo.get_by(PublicationAttemptRecord, message_id: candidate.message_id) do
      %PublicationAttemptRecord{} = persisted ->
        if PublicationAttemptRecordValidator.validate(persisted) == :ok and
             same_facts?(persisted, candidate),
           do: persisted,
           else: Repo.rollback(classify_attempt_error(persisted))

      nil ->
        Repo.rollback(:publication_attempt_conflict)
    end
  end

  defp restore_terminal(candidate) do
    case Repo.get_by(PublicationAttemptRecord, message_id: candidate.message_id) do
      %PublicationAttemptRecord{} = persisted -> identical_or_conflict(persisted, candidate)
      nil -> Repo.rollback(:publication_attempt_conflict)
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

  defp same_message_facts?(left, right),
    do: Map.take(left, @message_fields) == Map.take(right, @message_fields)

  defp valid_message_id?(id), do: is_integer(id) and id in 1..@max_sqlite_integer
end

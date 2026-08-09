defmodule ClusterMurmur.Persistence.TriggerExecutionStore do
  @moduledoc """
  Atomically records one validated event-trigger execution lifecycle.

  The transaction requires the immutable event to be committed unchanged,
  rejects a previously started trigger/event pair, rechecks the latest durable
  cooldown, and atomically advances the event dedupe marker before inserting a
  started record. Exact compare-and-set transitions then finish it once. The
  store never runs the action.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.DedupeEvaluator
  alias ClusterMurmur.Events.DedupeEvaluator.Marker

  alias ClusterMurmur.Persistence.{
    EventDedupeMarker,
    EventDedupeMarkerValidator,
    EventStore,
    TriggerExecution,
    TriggerExecutionValidator
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Triggers.TriggerExecutionRecovery
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan

  @error_class_pattern ~r/\A[a-z][a-z0-9._-]*\z/
  @max_error_class_bytes 128
  @max_recovery_executions 100

  @event_identity_fields [
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
    :labels
  ]

  @type error ::
          :event_conflict
          | :event_not_found
          | :execution_conflict
          | :invalid_datetime
          | :invalid_execution
          | :storage_unavailable

  @type skip_reason :: :already_terminal | :cooldown | :dedupe_window | :execution_in_progress

  @doc "Starts one plan when its event, deduplication key, and durable cooldown permit it."
  @spec start(term()) ::
          {:ok, TriggerExecution.t()} | {:skip, skip_reason()} | {:error, error()}
  def start(plan) do
    changeset = TriggerExecution.start_changeset(%TriggerExecution{}, plan)

    if changeset.valid? do
      persist_start(changeset, plan)
    else
      {:error, :invalid_execution}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Marks one exact started execution completed without changing its cooldown."
  @spec complete(term()) :: {:ok, TriggerExecution.t()} | {:error, error()}
  def complete(execution), do: finish(execution, :completed, nil)

  @doc "Marks one exact started execution failed with a bounded stable error class."
  @spec fail(term(), term()) :: {:ok, TriggerExecution.t()} | {:error, error()}
  def fail(execution, error_class), do: finish(execution, :failed, error_class)

  @doc "Lists at most 100 started executions at or before one supplied UTC cutoff."
  @spec list_started_before(term()) ::
          {:ok, [TriggerExecution.t()]}
          | {:error, :invalid_datetime | :invalid_execution | :storage_unavailable}
  def list_started_before(cutoff) do
    if DateTimeValidator.validate_storage_utc(cutoff) == :ok do
      query =
        from execution in TriggerExecution,
          where: execution.status == :started and execution.executed_at <= ^cutoff,
          order_by: [
            asc: execution.executed_at,
            asc: execution.trigger_id,
            asc: execution.event_id
          ],
          limit: @max_recovery_executions

      executions = Repo.all(query)

      if Enum.all?(executions, &(TriggerExecutionValidator.validate(&1) == :ok)),
        do: {:ok, executions},
        else: {:error, :invalid_execution}
    else
      {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Fails one abandoned started execution without retrying its action."
  @spec fail_abandoned(term(), term()) ::
          {:ok, TriggerExecution.t()}
          | {:skip, :recent | :terminal}
          | {:error, error()}
  def fail_abandoned(execution, cutoff) do
    case TriggerExecutionRecovery.classify(execution, cutoff) do
      {:ok, :abandoned} -> finish(execution, :failed, "runtime.interrupted")
      {:ok, reason} when reason in [:recent, :terminal] -> {:skip, reason}
      {:error, _reason} = error -> error
    end
  end

  defp finish(execution, status, error_class) do
    if valid_terminal_input?(execution, status, error_class) do
      persist_terminal(execution, status, error_class)
    else
      {:error, :invalid_execution}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp persist_start(changeset, %Plan{} = plan) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    case Repo.transaction(fn -> start_transaction(changeset, candidate, plan) end) do
      {:ok, %TriggerExecution{} = execution} ->
        {:ok, execution}

      {:error, {:skip, reason}}
      when reason in [:already_terminal, :cooldown, :dedupe_window, :execution_in_progress] ->
        {:skip, reason}

      {:error, reason}
      when reason in [:event_conflict, :event_not_found, :execution_conflict, :invalid_execution] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp start_transaction(changeset, candidate, plan) do
    with :ok <- require_identical_event(plan),
         :ok <- reject_existing_pair(candidate),
         :ok <- require_expired_cooldown(candidate),
         :ok <- accept_dedupe_marker(plan),
         {:ok, %TriggerExecution{} = execution} <- Repo.insert(changeset) do
      execution
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp require_identical_event(%Plan{} = plan) do
    case EventStore.fetch(plan.event.id) do
      {:ok, event} ->
        if identical_event?(event, plan.event), do: :ok, else: {:error, :event_conflict}

      {:error, :event_not_found} ->
        {:error, :event_not_found}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp identical_event?(persisted, planned) do
    Map.take(persisted, @event_identity_fields) === Map.take(planned, @event_identity_fields) and
      same_datetime?(persisted.occurred_at, planned.occurred_at) and
      same_optional_datetime?(persisted.observed_at, planned.observed_at)
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp same_optional_datetime?(nil, nil), do: true
  defp same_optional_datetime?(left, right), do: same_datetime?(left, right)

  defp reject_existing_pair(candidate) do
    case Repo.get_by(TriggerExecution,
           trigger_id: candidate.trigger_id,
           event_id: candidate.event_id
         ) do
      nil ->
        :ok

      %TriggerExecution{status: :started} = execution ->
        classify_existing_execution(execution, :execution_in_progress)

      %TriggerExecution{status: status} = execution when status in [:completed, :failed] ->
        classify_existing_execution(execution, :already_terminal)

      %TriggerExecution{} ->
        {:error, :invalid_execution}
    end
  end

  defp classify_existing_execution(execution, reason) do
    if TriggerExecutionValidator.validate(execution) == :ok,
      do: {:error, {:skip, reason}},
      else: {:error, :invalid_execution}
  end

  defp require_expired_cooldown(candidate) do
    query =
      from execution in TriggerExecution,
        where: execution.trigger_id == ^candidate.trigger_id,
        order_by: [desc: execution.cooldown_until, desc: execution.executed_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        :ok

      %TriggerExecution{cooldown_until: cooldown_until} ->
        if DateTime.compare(cooldown_until, candidate.executed_at) == :gt,
          do: {:error, {:skip, :cooldown}},
          else: :ok
    end
  end

  defp accept_dedupe_marker(%Plan{event: %{dedupe_key: nil}}), do: :ok

  defp accept_dedupe_marker(%Plan{} = plan) do
    with {:ok, persisted, marker} <- load_dedupe_marker(plan.event.dedupe_key),
         {:ok, decision} <-
           DedupeEvaluator.evaluate(plan.event, marker, plan.event_policy, plan.executed_at) do
      persist_dedupe_decision(decision, persisted)
    else
      {:error, :storage_unavailable} = error -> error
      {:error, :invalid_event_dedupe_marker} -> {:error, :invalid_execution}
      _failure -> {:error, :invalid_execution}
    end
  end

  defp load_dedupe_marker(dedupe_key) do
    case Repo.get(EventDedupeMarker, dedupe_key) do
      nil ->
        {:ok, nil, nil}

      %EventDedupeMarker{} = persisted ->
        with :ok <- EventDedupeMarkerValidator.validate(persisted),
             {:ok, marker_event} <- EventStore.fetch(persisted.event_id),
             true <- marker_event.dedupe_key === persisted.dedupe_key do
          {:ok, persisted,
           %Marker{
             dedupe_key: persisted.dedupe_key,
             event_id: persisted.event_id,
             accepted_at: persisted.accepted_at
           }}
        else
          {:error, :storage_unavailable} = error -> error
          _failure -> {:error, :invalid_event_dedupe_marker}
        end
    end
  end

  defp persist_dedupe_decision({:skip, :dedupe_window}, _persisted),
    do: {:error, {:skip, :dedupe_window}}

  defp persist_dedupe_decision({:accept, nil}, nil), do: :ok

  defp persist_dedupe_decision({:accept, %Marker{} = marker}, nil) do
    changeset = EventDedupeMarker.changeset(%EventDedupeMarker{}, marker)

    case Repo.insert(changeset) do
      {:ok, %EventDedupeMarker{}} -> :ok
      _failure -> {:error, :invalid_execution}
    end
  end

  defp persist_dedupe_decision({:accept, %Marker{} = marker}, persisted) do
    current = %Marker{
      dedupe_key: persisted.dedupe_key,
      event_id: persisted.event_id,
      accepted_at: persisted.accepted_at
    }

    if marker === current, do: :ok, else: replace_dedupe_marker(persisted, marker)
  end

  defp persist_dedupe_decision(_decision, _persisted), do: {:error, :invalid_execution}

  defp replace_dedupe_marker(persisted, marker) do
    query =
      from stored in EventDedupeMarker,
        where:
          stored.dedupe_key == ^persisted.dedupe_key and
            stored.event_id == ^persisted.event_id and
            stored.accepted_at == ^persisted.accepted_at

    case Repo.update_all(query, set: [event_id: marker.event_id, accepted_at: marker.accepted_at]) do
      {1, nil} -> :ok
      _failure -> {:error, :invalid_execution}
    end
  end

  defp valid_terminal_input?(execution, status, error_class) do
    TriggerExecutionValidator.validate_started(execution) == :ok and
      valid_terminal_status?(status, error_class)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_terminal_status?(:completed, nil), do: true

  defp valid_terminal_status?(:failed, error_class)
       when is_binary(error_class) and byte_size(error_class) in 1..@max_error_class_bytes do
    String.valid?(error_class) and not String.contains?(error_class, <<0>>) and
      Regex.match?(@error_class_pattern, error_class)
  end

  defp valid_terminal_status?(_status, _error_class), do: false

  defp persist_terminal(execution, status, error_class) do
    case Repo.transaction(fn -> compare_and_set_terminal(execution, status, error_class) end) do
      {:ok, %TriggerExecution{} = terminal} -> {:ok, terminal}
      {:error, :execution_conflict} -> {:error, :execution_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp compare_and_set_terminal(execution, status, error_class) do
    query =
      from persisted in TriggerExecution,
        where:
          persisted.trigger_id == ^execution.trigger_id and
            persisted.event_id == ^execution.event_id and
            persisted.status == :started and
            persisted.executed_at == ^execution.executed_at and
            persisted.cooldown_until == ^execution.cooldown_until and
            is_nil(persisted.error_class)

    case Repo.update_all(query, set: [status: status, error_class: error_class]) do
      {1, nil} -> restore_terminal(execution.trigger_id, execution.event_id)
      {0, nil} -> Repo.rollback(:execution_conflict)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp restore_terminal(trigger_id, event_id) do
    case Repo.get_by(TriggerExecution, trigger_id: trigger_id, event_id: event_id) do
      %TriggerExecution{} = terminal -> terminal
      nil -> Repo.rollback(:storage_unavailable)
    end
  end
end

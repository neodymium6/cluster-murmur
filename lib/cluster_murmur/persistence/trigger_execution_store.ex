defmodule ClusterMurmur.Persistence.TriggerExecutionStore do
  @moduledoc """
  Atomically records one validated event-trigger execution lifecycle.

  The transaction requires the immutable event to be committed unchanged,
  rejects a previously started trigger/event pair, and rechecks the latest
  durable cooldown before inserting a started record. Exact compare-and-set
  transitions then finish it once. The store never runs the action.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Events.Validator, as: EventValidator
  alias ClusterMurmur.Persistence.{EventStore, TriggerExecution}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan

  @execution_keys TriggerExecution.__struct__() |> Map.keys()
  @execution_key_count length(@execution_keys)
  @loaded_metadata Ecto.put_meta(%TriggerExecution{}, state: :loaded).__meta__
  @trigger_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @error_class_pattern ~r/\A[a-z][a-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_error_class_bytes 128

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
          | :invalid_execution
          | :storage_unavailable

  @doc "Starts one plan when its event, deduplication key, and durable cooldown permit it."
  @spec start(term()) ::
          {:ok, TriggerExecution.t()} | {:skip, :cooldown} | {:error, error()}
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

      {:error, {:skip, :cooldown}} ->
        {:skip, :cooldown}

      {:error, reason}
      when reason in [:event_conflict, :event_not_found, :execution_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp start_transaction(changeset, candidate, plan) do
    with :ok <- require_identical_event(plan),
         :ok <- reject_existing_pair(candidate),
         :ok <- require_expired_cooldown(candidate),
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
      nil -> :ok
      %TriggerExecution{} -> {:error, :execution_conflict}
    end
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

  defp valid_terminal_input?(execution, status, error_class) do
    exact_started_execution?(execution) and valid_terminal_status?(status, error_class)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp exact_started_execution?(
         %TriggerExecution{
           __meta__: metadata,
           trigger_id: trigger_id,
           event_id: event_id,
           status: :started,
           executed_at: executed_at,
           cooldown_until: cooldown_until,
           error_class: nil
         } = execution
       ) do
    map_size(execution) == @execution_key_count and
      Enum.all?(@execution_keys, &Map.has_key?(execution, &1)) and
      metadata == @loaded_metadata and
      valid_trigger_id?(trigger_id) and
      EventValidator.validate_id(event_id) == :ok and
      valid_loaded_datetime?(executed_at) and
      valid_loaded_datetime?(cooldown_until) and
      DateTime.compare(cooldown_until, executed_at) in [:gt, :eq]
  end

  defp exact_started_execution?(_execution), do: false

  defp valid_trigger_id?(trigger_id)
       when is_binary(trigger_id) and byte_size(trigger_id) <= @max_id_bytes do
    String.valid?(trigger_id) and Regex.match?(@trigger_id_pattern, trigger_id)
  end

  defp valid_trigger_id?(_trigger_id), do: false

  defp valid_loaded_datetime?(%DateTime{microsecond: {_value, 6}} = datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp valid_loaded_datetime?(_datetime), do: false

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

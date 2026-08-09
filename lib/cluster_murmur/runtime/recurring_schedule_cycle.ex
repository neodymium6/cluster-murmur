defmodule ClusterMurmur.Runtime.RecurringScheduleCycle do
  @moduledoc """
  Runs one bounded batch of due recurring schedules without external I/O.

  Every loaded state is correlated with the exact current configuration before
  the first claim. Valid states then cross the fixed claim, planning, event
  projection, and atomic commit boundaries in durable due order. An individual
  claim or commit conflict does not stop the remaining validated batch.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventRecord,
    ScheduleEventCommitStore,
    ScheduleState,
    ScheduleStateClaim,
    ScheduleStateStore
  }

  alias ClusterMurmur.Persistence.ScheduleEventCommitStore.Result, as: CommitResult

  alias ClusterMurmur.Triggers.{
    EmittedEventProjector,
    ScheduleExecutionPlanner,
    ScheduleTrigger
  }

  @due_page_size 100
  @max_due_schedules 256
  @event_record_fields [
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
  @state_keys ScheduleState.__struct__() |> Map.keys()
  @state_key_count length(@state_keys)
  @dispatch_receipt_keys EventDispatchReceipt.__struct__() |> Map.keys()
  @dispatch_receipt_key_count length(@dispatch_receipt_keys)
  @commit_result_keys CommitResult.__struct__() |> Map.keys()
  @commit_result_key_count length(@commit_result_keys)

  defmodule Adapters do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:states, :commits]
    defstruct [:states, :commits]

    @type t :: %__MODULE__{states: module(), commits: module()}
  end

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:due_count, :executed_count, :failure_count]}
    @enforce_keys [:due_count, :executed_count, :failure_count]
    defstruct [:due_count, :executed_count, :failure_count]

    @type t :: %__MODULE__{
            due_count: non_neg_integer(),
            executed_count: non_neg_integer(),
            failure_count: non_neg_integer()
          }
  end

  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)
  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)

  @doc "Runs one due recurring-schedule batch through the fixed durable stores."
  @spec run(term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_recurring_schedule_cycle}
  def run(configuration, now) do
    run(configuration, now, %Adapters{
      states: ScheduleStateStore,
      commits: ScheduleEventCommitStore
    })
  end

  @doc false
  @spec run(term(), term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_recurring_schedule_cycle}
  def run(%Configuration{} = configuration, %DateTime{} = now, %Adapters{} = adapters) do
    with :ok <- preflight(configuration, now, adapters),
         {:ok, entries} <- load_entries(configuration, now, adapters.states) do
      {:ok, execute_entries(entries, now, adapters)}
    else
      _failure -> {:error, :invalid_recurring_schedule_cycle}
    end
  rescue
    _error -> {:error, :invalid_recurring_schedule_cycle}
  catch
    _kind, _reason -> {:error, :invalid_recurring_schedule_cycle}
  end

  def run(_configuration, _now, _adapters),
    do: {:error, :invalid_recurring_schedule_cycle}

  @doc "Validates one exact bounded aggregate cycle result."
  @spec validate_result(term()) ::
          :ok | {:error, :invalid_recurring_schedule_cycle_result}
  def validate_result(%Result{} = result) do
    counts = [result.due_count, result.executed_count, result.failure_count]

    if exact_result?(result) and
         Enum.all?(counts, &(is_integer(&1) and &1 in 0..@max_due_schedules)) and
         result.due_count == result.executed_count + result.failure_count,
       do: :ok,
       else: {:error, :invalid_recurring_schedule_cycle_result}
  rescue
    _error -> {:error, :invalid_recurring_schedule_cycle_result}
  catch
    _kind, _reason -> {:error, :invalid_recurring_schedule_cycle_result}
  end

  def validate_result(_result), do: {:error, :invalid_recurring_schedule_cycle_result}

  defp preflight(configuration, now, adapters) do
    with :ok <- normalize_configuration(Configuration.validate(configuration)),
         :ok <- DateTimeValidator.validate_storage_utc(now),
         true <- exact_adapters?(adapters),
         :ok <- validate_adapter(adapters.states, list_due: 1, list_due_after: 2, claim_due: 3),
         :ok <- validate_adapter(adapters.commits, commit: 3) do
      :ok
    else
      _failure -> {:error, :invalid_recurring_schedule_cycle}
    end
  end

  defp load_entries(configuration, now, states) do
    case states.list_due(now) do
      {:ok, page} -> collect_pages(page, configuration, now, states, [], 0, nil)
      _failure -> {:error, :invalid_recurring_schedule_cycle}
    end
  end

  defp collect_pages(page, configuration, now, states, entries, count, previous)
       when is_list(page) do
    with {:ok, page_size} <- page_size(page),
         {:ok, entries, count, previous} <-
           prepare_page(page, configuration, now, entries, count, previous) do
      if page_size == @due_page_size do
        case states.list_due_after(now, previous) do
          {:ok, next_page} ->
            collect_pages(next_page, configuration, now, states, entries, count, previous)

          _failure ->
            {:error, :invalid_recurring_schedule_cycle}
        end
      else
        {:ok, Enum.reverse(entries)}
      end
    else
      _failure -> {:error, :invalid_recurring_schedule_cycle}
    end
  end

  defp collect_pages(_page, _configuration, _now, _states, _entries, _count, _previous),
    do: {:error, :invalid_recurring_schedule_cycle}

  defp page_size(page) do
    Enum.reduce_while(page, 0, fn _state, count ->
      if count < @due_page_size,
        do: {:cont, count + 1},
        else: {:halt, :oversized}
    end)
    |> case do
      :oversized -> {:error, :invalid_recurring_schedule_cycle}
      count -> {:ok, count}
    end
  end

  defp prepare_page(page, configuration, now, entries, count, previous) do
    Enum.reduce_while(page, {:ok, entries, count, previous}, fn state,
                                                                {:ok, entries, count, previous} ->
      if count < @max_due_schedules do
        case prepare_entry(state, configuration, now) do
          {:ok, entry} ->
            cursor = state_cursor(state)

            if strictly_after?(cursor, previous),
              do: {:cont, {:ok, [entry | entries], count + 1, cursor}},
              else: {:halt, {:error, :invalid_recurring_schedule_cycle}}

          {:error, :invalid_recurring_schedule_cycle} = error ->
            {:halt, error}
        end
      else
        {:halt, {:error, :invalid_recurring_schedule_cycle}}
      end
    end)
  end

  defp prepare_entry(%ScheduleState{trigger_id: trigger_id} = state, configuration, now) do
    case Map.fetch(configuration.triggers.triggers, trigger_id) do
      {:ok, %ScheduleTrigger{id: ^trigger_id} = trigger} ->
        if valid_due_state?(state, now),
          do: {:ok, {trigger, state}},
          else: {:error, :invalid_recurring_schedule_cycle}

      _missing_or_wrong_type ->
        {:error, :invalid_recurring_schedule_cycle}
    end
  end

  defp prepare_entry(_state, _configuration, _now),
    do: {:error, :invalid_recurring_schedule_cycle}

  defp valid_due_state?(state, now) do
    exact_state?(state) and ScheduleState.changeset(state, %{}).valid? and
      state.claim_token == nil and state.claim_started_at == nil and
      state.claim_expires_at == nil and DateTime.compare(state.next_run_at, now) in [:lt, :eq]
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp state_cursor(state), do: {state.next_run_at, state.trigger_id}

  defp strictly_after?(_cursor, nil), do: true

  defp strictly_after?({next_run_at, trigger_id}, {previous_run_at, previous_trigger_id}) do
    case DateTime.compare(next_run_at, previous_run_at) do
      :gt -> true
      :eq -> trigger_id > previous_trigger_id
      :lt -> false
    end
  end

  defp execute_entries(entries, now, adapters) do
    {executed, failures} =
      Enum.reduce(entries, {0, 0}, fn {trigger, state}, {executed, failures} ->
        case execute_one(trigger, state, now, adapters) do
          :ok -> {executed + 1, failures}
          :error -> {executed, failures + 1}
        end
      end)

    %Result{
      due_count: length(entries),
      executed_count: executed,
      failure_count: failures
    }
  end

  defp execute_one(trigger, state, now, adapters) do
    with {:ok, %ScheduleStateClaim{} = claim} <-
           adapters.states.claim_due(trigger.id, state.next_run_at, now),
         :ok <- validate_claim_correlation(claim, trigger, state, now),
         {:ok, plan} <- ScheduleExecutionPlanner.plan(trigger, state, claim, now),
         {:ok, event} <-
           EmittedEventProjector.project(:schedule, trigger.id, plan.event, state.next_run_at),
         {:ok, %CommitResult{} = committed} <- adapters.commits.commit(plan, event, now),
         :ok <- validate_commit_correlation(committed, event, plan) do
      :ok
    else
      _failure -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp validate_claim_correlation(claim, trigger, state, now) do
    if claim.trigger_id == trigger.id and
         same_time?(claim.expected_next_run_at, state.next_run_at) and
         same_time?(claim.started_at, now),
       do: :ok,
       else: {:error, :invalid_recurring_schedule_cycle}
  end

  defp validate_commit_correlation(
         %CommitResult{
           dispatch: %EventDispatchReceipt{} = dispatch,
           event: %EventRecord{} = record,
           state: %ScheduleState{} = committed_state
         } = result,
         event,
         plan
       ) do
    with true <- exact_commit_result?(result),
         true <- event_record_matches?(record, event),
         true <- dispatch_matches?(dispatch, event, plan.executed_at),
         true <- completed_state_matches?(committed_state, plan) do
      :ok
    else
      _failure -> {:error, :invalid_recurring_schedule_cycle}
    end
  end

  defp validate_commit_correlation(_committed, _event, _plan),
    do: {:error, :invalid_recurring_schedule_cycle}

  defp event_record_matches?(record, event) do
    changeset = EventRecord.changeset(%EventRecord{}, event)

    changeset.valid? and
      Map.take(record, @event_record_fields) ==
        changeset |> Ecto.Changeset.apply_changes() |> Map.take(@event_record_fields)
  end

  defp dispatch_matches?(dispatch, event, recorded_at) do
    exact_dispatch_receipt?(dispatch) and dispatch.event_id == event.id and
      dispatch.status == :pending and same_time?(dispatch.enqueued_at, recorded_at)
  end

  defp completed_state_matches?(state, plan) do
    exact_state?(state) and ScheduleState.changeset(state, %{}).valid? and
      state.trigger_id == plan.claim.trigger_id and
      same_time?(state.last_run_at, plan.executed_at) and
      same_time?(state.next_run_at, plan.next_run_at) and state.claim_token == nil and
      state.claim_started_at == nil and state.claim_expires_at == nil
  end

  defp same_time?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_time?(_left, _right), do: false

  defp validate_adapter(adapter, callbacks) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end),
       do: :ok,
       else: {:error, :invalid_recurring_schedule_cycle}
  end

  defp normalize_configuration(:ok), do: :ok
  defp normalize_configuration(_failure), do: {:error, :invalid_recurring_schedule_cycle}

  defp exact_adapters?(adapters), do: exact?(adapters, @adapter_keys, @adapter_key_count)
  defp exact_state?(state), do: exact?(state, @state_keys, @state_key_count)

  defp exact_dispatch_receipt?(receipt),
    do: exact?(receipt, @dispatch_receipt_keys, @dispatch_receipt_key_count)

  defp exact_commit_result?(result),
    do: exact?(result, @commit_result_keys, @commit_result_key_count)

  defp exact_result?(result), do: exact?(result, @result_keys, @result_key_count)

  defp exact?(value, keys, key_count) do
    map_size(value) == key_count and Enum.all?(keys, &Map.has_key?(value, &1))
  end
end

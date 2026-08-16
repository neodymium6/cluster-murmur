defmodule ClusterMurmur.Runtime.StochasticCycle do
  @moduledoc """
  Runs one bounded batch of due stochastic schedules without external I/O.

  Every loaded schedule is correlated with the exact current configuration and
  evaluated before the first claim. Eligible schedules then cross the fixed
  claim, planning, event projection, and atomic commit boundaries in durable
  due order. Individual claim or commit conflicts do not stop the remaining
  validated batch.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventRecord,
    StochasticEventCommitStore,
    StochasticSchedule,
    StochasticScheduleClaim,
    StochasticScheduleStore
  }

  alias ClusterMurmur.Persistence.StochasticEventCommitStore.Result, as: CommitResult

  alias ClusterMurmur.Triggers.{
    EmittedEventProjector,
    StochasticDueEvaluator,
    StochasticExecutionPlanner,
    StochasticScheduleCalculator,
    StochasticTrigger
  }

  alias ClusterMurmur.Triggers.StochasticEligibility.Decision

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
  @schedule_fields [
    :trigger_id,
    :next_run_at,
    :last_run_at,
    :daily_count,
    :daily_count_date,
    :claim_token,
    :claim_started_at,
    :claim_expires_at
  ]
  @dispatch_receipt_keys EventDispatchReceipt.__struct__() |> Map.keys()
  @dispatch_receipt_key_count length(@dispatch_receipt_keys)
  @commit_result_keys CommitResult.__struct__() |> Map.keys()
  @commit_result_key_count length(@commit_result_keys)

  defmodule Adapters do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:schedules, :commits]
    defstruct [:schedules, :commits]

    @type t :: %__MODULE__{schedules: module(), commits: module()}
  end

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:due_count, :executed_count, :skipped_count, :failure_count]}
    @enforce_keys [:due_count, :executed_count, :skipped_count, :failure_count]
    defstruct [:due_count, :executed_count, :skipped_count, :failure_count]

    @type t :: %__MODULE__{
            due_count: non_neg_integer(),
            executed_count: non_neg_integer(),
            skipped_count: non_neg_integer(),
            failure_count: non_neg_integer()
          }
  end

  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)
  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)

  @doc "Runs one due batch through the fixed durable stores."
  @spec run(term(), term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_stochastic_cycle}
  def run(configuration, now, random) do
    run(configuration, now, random, %Adapters{
      schedules: StochasticScheduleStore,
      commits: StochasticEventCommitStore
    })
  end

  @doc false
  @spec run(term(), term(), term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_stochastic_cycle}
  def run(%Configuration{} = configuration, %DateTime{} = now, random, %Adapters{} = adapters) do
    with :ok <- preflight(configuration, now, random, adapters),
         {:ok, entries} <- load_entries(configuration, now, adapters.schedules) do
      {:ok, execute_entries(entries, now, random, adapters)}
    else
      _failure -> {:error, :invalid_stochastic_cycle}
    end
  rescue
    _error -> {:error, :invalid_stochastic_cycle}
  catch
    _kind, _reason -> {:error, :invalid_stochastic_cycle}
  end

  def run(_configuration, _now, _random, _adapters),
    do: {:error, :invalid_stochastic_cycle}

  @doc "Validates one exact bounded aggregate cycle result."
  @spec validate_result(term()) :: :ok | {:error, :invalid_stochastic_cycle_result}
  def validate_result(%Result{} = result) do
    counts = [result.due_count, result.executed_count, result.skipped_count, result.failure_count]

    if exact_result?(result) and
         Enum.all?(counts, &(is_integer(&1) and &1 in 0..@max_due_schedules)) and
         result.due_count == result.executed_count + result.skipped_count + result.failure_count,
       do: :ok,
       else: {:error, :invalid_stochastic_cycle_result}
  rescue
    _error -> {:error, :invalid_stochastic_cycle_result}
  catch
    _kind, _reason -> {:error, :invalid_stochastic_cycle_result}
  end

  def validate_result(_result), do: {:error, :invalid_stochastic_cycle_result}

  defp preflight(configuration, now, random, adapters) do
    with :ok <- normalize_configuration(Configuration.validate(configuration)),
         :ok <- DateTimeValidator.validate_storage_utc(now),
         :ok <- validate_random(random),
         true <- exact_adapters?(adapters),
         :ok <-
           validate_adapter(adapters.schedules,
             list_due: 1,
             list_due_after: 2,
             claim_due: 3,
             reschedule: 3
           ),
         :ok <- validate_adapter(adapters.commits, commit: 3) do
      :ok
    else
      _failure -> {:error, :invalid_stochastic_cycle}
    end
  end

  defp load_entries(configuration, now, schedules) do
    case schedules.list_due(now) do
      {:ok, page} -> collect_pages(page, configuration, now, schedules, [], 0, nil)
      _failure -> {:error, :invalid_stochastic_cycle}
    end
  end

  defp collect_pages(page, configuration, now, schedules, entries, count, previous)
       when is_list(page) do
    with {:ok, page_size} <- page_size(page),
         {:ok, entries, count, previous} <-
           prepare_page(page, configuration, now, entries, count, previous) do
      if page_size == @due_page_size do
        case schedules.list_due_after(now, previous) do
          {:ok, next_page} ->
            collect_pages(
              next_page,
              configuration,
              now,
              schedules,
              entries,
              count,
              previous
            )

          _failure ->
            {:error, :invalid_stochastic_cycle}
        end
      else
        {:ok, Enum.reverse(entries)}
      end
    else
      _failure -> {:error, :invalid_stochastic_cycle}
    end
  end

  defp collect_pages(
         _page,
         _configuration,
         _now,
         _schedules,
         _entries,
         _count,
         _previous
       ),
       do: {:error, :invalid_stochastic_cycle}

  defp page_size(page) do
    Enum.reduce_while(page, 0, fn _schedule, count ->
      if count < @due_page_size,
        do: {:cont, count + 1},
        else: {:halt, :oversized}
    end)
    |> case do
      :oversized -> {:error, :invalid_stochastic_cycle}
      count -> {:ok, count}
    end
  end

  defp prepare_page(page, configuration, now, entries, count, previous) do
    Enum.reduce_while(page, {:ok, entries, count, previous}, fn schedule,
                                                                {:ok, entries, count, previous} ->
      if count < @max_due_schedules do
        case prepare_entry(schedule, configuration, now) do
          {:ok, entry} ->
            cursor = schedule_cursor(schedule)

            if strictly_after?(cursor, previous),
              do: {:cont, {:ok, [entry | entries], count + 1, cursor}},
              else: {:halt, {:error, :invalid_stochastic_cycle}}

          {:error, :invalid_stochastic_cycle} = error ->
            {:halt, error}
        end
      else
        {:halt, {:error, :invalid_stochastic_cycle}}
      end
    end)
  end

  defp prepare_entry(
         %StochasticSchedule{trigger_id: trigger_id} = schedule,
         configuration,
         now
       ) do
    case Map.fetch(configuration.triggers.triggers, trigger_id) do
      {:ok, %StochasticTrigger{id: ^trigger_id} = trigger} ->
        case StochasticDueEvaluator.evaluate(trigger, schedule, now) do
          {:ok, %Decision{} = decision} -> {:ok, {trigger, schedule, decision}}
          _failure -> {:error, :invalid_stochastic_cycle}
        end

      _missing_or_wrong_type ->
        {:error, :invalid_stochastic_cycle}
    end
  end

  defp prepare_entry(_schedule, _configuration, _now),
    do: {:error, :invalid_stochastic_cycle}

  defp schedule_cursor(schedule), do: {schedule.next_run_at, schedule.trigger_id}

  defp strictly_after?(_cursor, nil), do: true

  defp strictly_after?({next_run_at, trigger_id}, {previous_run_at, previous_trigger_id}) do
    case DateTime.compare(next_run_at, previous_run_at) do
      :gt -> true
      :eq -> trigger_id > previous_trigger_id
      :lt -> false
    end
  end

  defp execute_entries(entries, now, random, adapters) do
    {executed, skipped, failures} =
      Enum.reduce(entries, {0, 0, 0}, fn
        {trigger, schedule, %Decision{eligible: false, reason: :outside_active_hours}},
        {executed, skipped, failures} ->
          case reschedule_one(trigger, schedule, now, random, adapters.schedules) do
            :ok -> {executed, skipped + 1, failures}
            :error -> {executed, skipped, failures + 1}
          end

        {_trigger, _schedule, %Decision{eligible: false}}, {executed, skipped, failures} ->
          {executed, skipped + 1, failures}

        {trigger, schedule, %Decision{eligible: true}}, {executed, skipped, failures} ->
          case execute_one(trigger, schedule, now, random, adapters) do
            :ok -> {executed + 1, skipped, failures}
            :error -> {executed, skipped, failures + 1}
          end
      end)

    %Result{
      due_count: length(entries),
      executed_count: executed,
      skipped_count: skipped,
      failure_count: failures
    }
  end

  defp reschedule_one(trigger, schedule, now, random, schedules) do
    with {:ok, next_run_at} <-
           StochasticScheduleCalculator.next_active_run(trigger, now, random),
         {:ok, %StochasticScheduleClaim{} = claim} <-
           schedules.claim_due(trigger.id, schedule.next_run_at, now),
         :ok <- validate_claim_correlation(claim, trigger, schedule, now),
         {:ok, %StochasticSchedule{} = rescheduled} <-
           schedules.reschedule(claim, now, next_run_at),
         :ok <- validate_reschedule_correlation(rescheduled, schedule, next_run_at) do
      :ok
    else
      _failure -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp execute_one(trigger, schedule, now, random, adapters) do
    with {:ok, %StochasticScheduleClaim{} = claim} <-
           adapters.schedules.claim_due(trigger.id, schedule.next_run_at, now),
         :ok <- validate_claim_correlation(claim, trigger, schedule, now),
         {:ok, plan} <- StochasticExecutionPlanner.plan(trigger, schedule, claim, now, random),
         {:ok, event} <-
           EmittedEventProjector.project(
             :stochastic,
             trigger.id,
             plan.event,
             schedule.next_run_at,
             plan.executed_at
           ),
         {:ok, %CommitResult{} = committed} <- adapters.commits.commit(plan, event, now),
         :ok <- validate_commit_correlation(committed, event, plan, schedule) do
      :ok
    else
      _failure -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp validate_claim_correlation(claim, trigger, schedule, now) do
    if claim.trigger_id == trigger.id and
         claim.expected_next_run_at == schedule.next_run_at and claim.started_at == now,
       do: :ok,
       else: {:error, :invalid_stochastic_cycle}
  end

  defp validate_reschedule_correlation(rescheduled, original, next_run_at) do
    expected = %{
      trigger_id: original.trigger_id,
      next_run_at: next_run_at,
      last_run_at: original.last_run_at,
      daily_count: original.daily_count,
      daily_count_date: original.daily_count_date,
      claim_token: nil,
      claim_started_at: nil,
      claim_expires_at: nil
    }

    if Map.take(rescheduled, @schedule_fields) == expected,
      do: :ok,
      else: {:error, :invalid_stochastic_cycle}
  end

  defp validate_commit_correlation(
         %CommitResult{
           dispatch: %EventDispatchReceipt{} = dispatch,
           event: %EventRecord{} = record,
           schedule: %StochasticSchedule{} = committed_schedule
         } = result,
         event,
         plan,
         original
       ) do
    with true <- exact_commit_result?(result),
         true <- event_record_matches?(record, event),
         true <- dispatch_matches?(dispatch, event, plan.executed_at),
         {:ok, daily_count, daily_count_date} <- expected_daily_state(original, plan.local_date),
         true <-
           Map.take(committed_schedule, @schedule_fields) == %{
             trigger_id: plan.claim.trigger_id,
             next_run_at: plan.next_run_at,
             last_run_at: plan.executed_at,
             daily_count: daily_count,
             daily_count_date: daily_count_date,
             claim_token: nil,
             claim_started_at: nil,
             claim_expires_at: nil
           } do
      :ok
    else
      _failure -> {:error, :invalid_stochastic_cycle}
    end
  end

  defp validate_commit_correlation(_committed, _event, _plan, _original),
    do: {:error, :invalid_stochastic_cycle}

  defp exact_commit_result?(result) do
    map_size(result) == @commit_result_key_count and
      Enum.all?(@commit_result_keys, &Map.has_key?(result, &1))
  end

  defp event_record_matches?(record, event) do
    changeset = EventRecord.changeset(%EventRecord{}, event)

    changeset.valid? and
      Map.take(record, @event_record_fields) ==
        changeset |> Ecto.Changeset.apply_changes() |> Map.take(@event_record_fields)
  end

  defp dispatch_matches?(dispatch, event, recorded_at) do
    dispatch.event_id == event.id and dispatch.status == :pending and
      dispatch.enqueued_at == recorded_at and
      map_size(dispatch) == @dispatch_receipt_key_count and
      Enum.all?(@dispatch_receipt_keys, &Map.has_key?(dispatch, &1))
  end

  defp expected_daily_state(_original, nil), do: {:ok, 0, nil}

  defp expected_daily_state(
         %StochasticSchedule{daily_count: count, daily_count_date: local_date},
         local_date
       )
       when is_integer(count) and count in 0..9_999,
       do: {:ok, count + 1, local_date}

  defp expected_daily_state(%StochasticSchedule{}, %Date{} = local_date),
    do: {:ok, 1, local_date}

  defp expected_daily_state(_original, _local_date),
    do: {:error, :invalid_stochastic_cycle}

  defp validate_random(random) do
    if is_atom(random) and Code.ensure_loaded?(random) and
         function_exported?(random, :uniform, 0),
       do: :ok,
       else: {:error, :invalid_stochastic_cycle}
  end

  defp validate_adapter(adapter, callbacks) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end),
       do: :ok,
       else: {:error, :invalid_stochastic_cycle}
  end

  defp normalize_configuration(:ok), do: :ok
  defp normalize_configuration(_failure), do: {:error, :invalid_stochastic_cycle}

  defp exact_adapters?(adapters) do
    map_size(adapters) == @adapter_key_count and
      Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
  end

  defp exact_result?(result) do
    map_size(result) == @result_key_count and Enum.all?(@result_keys, &Map.has_key?(result, &1))
  end
end

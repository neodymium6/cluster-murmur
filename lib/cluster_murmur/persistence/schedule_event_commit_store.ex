defmodule ClusterMurmur.Persistence.ScheduleEventCommitStore do
  @moduledoc """
  Atomically commits one claimed recurring event, dispatch handoff, and next state.

  No observer, provider, publication transport, clock, or generic repository
  operation crosses this fixed boundary.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.Event

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventDispatchStore,
    EventRecord,
    EventStore,
    ScheduleState,
    ScheduleStateClaim,
    ScheduleStateStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Triggers.EmittedEventProjector
  alias ClusterMurmur.Triggers.ScheduleExecutionPlanner.Plan

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:event, :dispatch, :state]
    defstruct [:event, :dispatch, :state]

    @type t :: %__MODULE__{
            event: ClusterMurmur.Persistence.EventRecord.t(),
            dispatch: ClusterMurmur.Persistence.EventDispatchReceipt.t(),
            state: ClusterMurmur.Persistence.ScheduleState.t()
          }
  end

  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)
  @claim_keys ScheduleStateClaim.__struct__() |> Map.keys()
  @claim_key_count length(@claim_keys)
  @claim_lease_seconds 60
  @claim_token_bytes 32

  @type error ::
          :invalid_schedule_event_commit
          | :schedule_event_conflict
          | :storage_unavailable

  @doc "Commits one exact event, dispatch handoff, and claimed schedule atomically."
  @spec commit(term(), term(), term()) :: {:ok, Result.t()} | {:error, error()}
  def commit(%Plan{} = plan, %Event{} = event, recorded_at) do
    with :ok <- validate(plan, event, recorded_at) do
      persist(plan, event, recorded_at)
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def commit(_plan, _event, _recorded_at), do: {:error, :invalid_schedule_event_commit}

  defp validate(plan, event, recorded_at) do
    with true <- exact_plan?(plan),
         :ok <- validate_claim(plan.claim),
         :ok <- validate_plan_times(plan, recorded_at),
         {:ok, expected_event} <-
           EmittedEventProjector.project(
             :schedule,
             plan.claim.trigger_id,
             plan.event,
             plan.claim.expected_next_run_at
           ),
         true <- event == expected_event,
         true <- DateTime.compare(plan.next_run_at, plan.executed_at) == :gt do
      :ok
    else
      _failure -> {:error, :invalid_schedule_event_commit}
    end
  end

  defp validate_claim(%ScheduleStateClaim{} = claim) do
    with true <- exact_claim?(claim),
         true <- valid_claim_token?(claim.token),
         :ok <- DateTimeValidator.validate_storage_utc(claim.expected_next_run_at),
         :ok <- DateTimeValidator.validate_storage_utc(claim.started_at),
         :ok <- DateTimeValidator.validate_storage_utc(claim.expires_at),
         true <- fixed_lease?(claim.started_at, claim.expires_at) do
      :ok
    else
      _failure -> {:error, :invalid_schedule_event_commit}
    end
  end

  defp validate_claim(_claim), do: {:error, :invalid_schedule_event_commit}

  defp validate_plan_times(plan, recorded_at) do
    with :ok <- DateTimeValidator.validate_storage_utc(plan.executed_at),
         :ok <- DateTimeValidator.validate_storage_utc(plan.next_run_at),
         :ok <- DateTimeValidator.validate_storage_utc(recorded_at),
         true <-
           DateTime.compare(plan.claim.expected_next_run_at, plan.claim.started_at) in [:lt, :eq],
         true <- DateTime.compare(plan.claim.started_at, plan.executed_at) in [:lt, :eq],
         true <- DateTime.compare(plan.executed_at, recorded_at) in [:lt, :eq],
         true <- DateTime.compare(recorded_at, plan.claim.expires_at) == :lt do
      :ok
    else
      _failure -> {:error, :invalid_schedule_event_commit}
    end
  end

  defp fixed_lease?(started_at, expires_at) do
    started_at
    |> DateTime.add(@claim_lease_seconds, :second)
    |> DateTime.compare(expires_at) == :eq
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_claim_token?(token) when is_binary(token) and byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == @claim_token_bytes
      :error -> false
    end
  end

  defp valid_claim_token?(_token), do: false

  defp persist(plan, event, recorded_at) do
    case Repo.transaction(fn -> persist_transaction(plan, event, recorded_at) end,
           mode: :immediate
         ) do
      {:ok,
       {%EventRecord{} = event_record, %EventDispatchReceipt{} = dispatch,
        %ScheduleState{} = state}} ->
        {:ok, %Result{event: event_record, dispatch: dispatch, state: state}}

      {:error, reason}
      when reason in [:invalid_schedule_event_commit, :schedule_event_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp persist_transaction(plan, event, recorded_at) do
    with {:ok, %EventRecord{} = event_record} <- insert_event(event),
         {:ok, %EventDispatchReceipt{status: :pending} = dispatch} <-
           enqueue_event(event, recorded_at),
         {:ok, %ScheduleState{} = state} <- advance_schedule(plan, recorded_at) do
      {event_record, dispatch, state}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_event(event) do
    case EventStore.insert(event) do
      {:ok, %EventRecord{} = record} -> {:ok, record}
      {:error, :event_conflict} -> {:error, :schedule_event_conflict}
      {:error, :invalid_event} -> {:error, :invalid_schedule_event_commit}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp enqueue_event(event, recorded_at) do
    case EventDispatchStore.enqueue(event, recorded_at) do
      {:ok, %EventDispatchReceipt{status: :pending} = receipt} ->
        {:ok, receipt}

      {:ok, %EventDispatchReceipt{}} ->
        {:error, :schedule_event_conflict}

      {:error, reason} when reason in [:dispatch_conflict, :event_conflict] ->
        {:error, :schedule_event_conflict}

      {:error, reason} when reason in [:invalid_datetime, :invalid_dispatch, :invalid_event] ->
        {:error, :invalid_schedule_event_commit}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp advance_schedule(plan, recorded_at) do
    case ScheduleStateStore.record_execution(
           plan.claim,
           plan.executed_at,
           recorded_at,
           plan.next_run_at
         ) do
      {:ok, %ScheduleState{} = state} -> {:ok, state}
      {:error, :invalid_schedule} -> {:error, :invalid_schedule_event_commit}
      {:error, :schedule_conflict} -> {:error, :schedule_event_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end

  defp exact_claim?(claim) do
    map_size(claim) == @claim_key_count and Enum.all?(@claim_keys, &Map.has_key?(claim, &1))
  end
end

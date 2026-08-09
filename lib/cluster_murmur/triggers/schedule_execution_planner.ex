defmodule ClusterMurmur.Triggers.ScheduleExecutionPlanner do
  @moduledoc """
  Plans one claimed recurring schedule execution without side effects.

  The redacted plan contains only the exact opaque claim, application-supplied
  event facts, supplied execution instant, and calculated next run required by
  a later atomic commit boundary.
  """

  alias ClusterMurmur.Config.Value
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.{ScheduleState, ScheduleStateClaim}
  alias ClusterMurmur.Triggers.{CronValidator, EmittedEvent, ScheduleCalculator, ScheduleTrigger}

  @claim_lease_seconds 60
  @claim_token_bytes 32
  @max_timezone_bytes 128
  @trigger_keys ScheduleTrigger.__struct__() |> Map.keys()
  @trigger_key_count length(@trigger_keys)
  @event_keys EmittedEvent.__struct__() |> Map.keys()
  @event_key_count length(@event_keys)
  @claim_keys ScheduleStateClaim.__struct__() |> Map.keys()
  @claim_key_count length(@claim_keys)

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:claim, :event, :executed_at, :next_run_at]
    defstruct [:claim, :event, :executed_at, :next_run_at]

    @type t :: %__MODULE__{
            claim: ClusterMurmur.Persistence.ScheduleStateClaim.t(),
            event: ClusterMurmur.Triggers.EmittedEvent.t(),
            executed_at: DateTime.t(),
            next_run_at: DateTime.t()
          }
  end

  @type error ::
          :invalid_claim
          | :invalid_datetime
          | :invalid_schedule
          | :invalid_trigger
          | :no_next_run
          | :schedule_not_due

  @doc "Builds a redacted plan for one exact live recurring-schedule claim."
  @spec plan(term(), term(), term(), term()) :: {:ok, Plan.t()} | {:error, error()}
  def plan(
        %ScheduleTrigger{} = trigger,
        %ScheduleState{} = state,
        %ScheduleStateClaim{} = claim,
        executed_at
      ) do
    with :ok <- validate_trigger(trigger),
         :ok <- validate_state(trigger, state),
         :ok <- validate_executed_at(executed_at),
         :ok <- validate_due(state.next_run_at, executed_at),
         :ok <- validate_claim(trigger, state, claim, executed_at),
         {:ok, next_run_at} <- calculate_next_run(trigger, executed_at) do
      {:ok,
       %Plan{
         claim: claim,
         event: trigger.event,
         executed_at: executed_at,
         next_run_at: next_run_at
       }}
    end
  rescue
    _error -> {:error, :invalid_schedule}
  catch
    _kind, _reason -> {:error, :invalid_schedule}
  end

  def plan(%ScheduleTrigger{}, %ScheduleState{}, _claim, _executed_at),
    do: {:error, :invalid_claim}

  def plan(%ScheduleTrigger{}, _state, _claim, _executed_at),
    do: {:error, :invalid_schedule}

  def plan(_trigger, _state, _claim, _executed_at), do: {:error, :invalid_trigger}

  defp validate_trigger(
         %ScheduleTrigger{timezone: timezone, action: :emit_event, event: %EmittedEvent{} = event} =
           trigger
       ) do
    if exact_keys?(trigger, @trigger_keys, @trigger_key_count) and valid_id?(trigger.id) and
         CronValidator.valid?(trigger.cron) and valid_timezone?(timezone) and valid_event?(event),
       do: :ok,
       else: {:error, :invalid_trigger}
  end

  defp validate_trigger(_trigger), do: {:error, :invalid_trigger}

  defp validate_state(
         %ScheduleTrigger{id: trigger_id},
         %ScheduleState{
           trigger_id: trigger_id,
           claim_token: nil,
           claim_started_at: nil,
           claim_expires_at: nil
         } = state
       ) do
    if ScheduleState.changeset(state, %{}).valid?,
      do: :ok,
      else: {:error, :invalid_schedule}
  end

  defp validate_state(%ScheduleTrigger{}, %ScheduleState{}), do: {:error, :invalid_schedule}

  defp validate_executed_at(executed_at) do
    if DateTimeValidator.validate_storage_utc(executed_at) == :ok,
      do: :ok,
      else: {:error, :invalid_datetime}
  end

  defp validate_due(next_run_at, executed_at) do
    if DateTime.compare(next_run_at, executed_at) in [:lt, :eq],
      do: :ok,
      else: {:error, :schedule_not_due}
  end

  defp calculate_next_run(trigger, executed_at) do
    case ScheduleCalculator.next_run(trigger, executed_at) do
      {:ok, next_run_at} ->
        if valid_storage_datetime?(next_run_at),
          do: {:ok, next_run_at},
          else: {:error, :no_next_run}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_claim(
         %ScheduleTrigger{id: trigger_id},
         %ScheduleState{trigger_id: trigger_id, next_run_at: expected_next_run_at},
         %ScheduleStateClaim{
           trigger_id: trigger_id,
           expected_next_run_at: expected_next_run_at,
           token: token,
           started_at: started_at,
           expires_at: expires_at
         } = claim,
         executed_at
       ) do
    if exact_keys?(claim, @claim_keys, @claim_key_count) and valid_claim_token?(token) and
         valid_storage_datetime?(started_at) and valid_storage_datetime?(expires_at) and
         fixed_lease?(started_at, expires_at) and
         DateTime.compare(expected_next_run_at, started_at) in [:lt, :eq] and
         DateTime.compare(started_at, executed_at) in [:lt, :eq] and
         DateTime.compare(executed_at, expires_at) == :lt do
      :ok
    else
      {:error, :invalid_claim}
    end
  end

  defp validate_claim(_trigger, _state, _claim, _executed_at),
    do: {:error, :invalid_claim}

  defp valid_event?(%EmittedEvent{} = event) do
    exact_keys?(event, @event_keys, @event_key_count) and valid_id?(event.type) and
      valid_id?(event.group) and valid_id?(event.subject)
  end

  defp valid_event?(_event), do: false

  defp valid_id?(value), do: match?({:ok, ^value}, Value.id(value))

  defp valid_timezone?(timezone)
       when is_binary(timezone) and byte_size(timezone) in 1..@max_timezone_bytes do
    String.valid?(timezone) and timezone in TimeZoneInfo.time_zones()
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_timezone?(_timezone), do: false

  defp valid_claim_token?(token) when is_binary(token) and byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == @claim_token_bytes
      :error -> false
    end
  end

  defp valid_claim_token?(_token), do: false

  defp fixed_lease?(started_at, expires_at) do
    started_at
    |> DateTime.add(@claim_lease_seconds, :second)
    |> DateTime.compare(expires_at) == :eq
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_storage_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp exact_keys?(value, keys, key_count) do
    map_size(value) == key_count and Enum.all?(keys, &Map.has_key?(value, &1))
  end
end

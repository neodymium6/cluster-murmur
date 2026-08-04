defmodule ClusterMurmur.Triggers.StochasticExecutionPlanner do
  @moduledoc """
  Plans one claimed stochastic execution without performing side effects.

  The plan contains only application-supplied event facts and the exact values
  needed to record a successful execution. It is fully redacted from inspection.
  """

  alias ClusterMurmur.Config.Value
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.{StochasticSchedule, StochasticScheduleClaim}
  alias ClusterMurmur.Triggers.{EmittedEvent, StochasticDueEvaluator}
  alias ClusterMurmur.Triggers.{StochasticScheduleCalculator, StochasticTrigger}
  alias ClusterMurmur.Triggers.StochasticEligibility.Decision

  @claim_lease_seconds 60
  @claim_token_bytes 32
  @max_id_bytes 16 * 1_024

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:claim, :event, :executed_at, :next_run_at, :local_date]
    defstruct [:claim, :event, :executed_at, :next_run_at, :local_date]

    @type t :: %__MODULE__{
            claim: ClusterMurmur.Persistence.StochasticScheduleClaim.t(),
            event: ClusterMurmur.Triggers.EmittedEvent.t(),
            executed_at: DateTime.t(),
            next_run_at: DateTime.t(),
            local_date: Date.t() | nil
          }
  end

  @type error ::
          :invalid_claim
          | :invalid_datetime
          | :invalid_random_source
          | :invalid_random_value
          | :invalid_schedule
          | :invalid_trigger
          | :no_next_run
          | :schedule_not_due

  @doc "Returns a redacted plan, or the factual reason that execution must be skipped."
  @spec plan(term(), term(), term(), term(), term()) ::
          {:ok, Plan.t()} | {:skip, Decision.t()} | {:error, error()}
  def plan(
        %StochasticTrigger{} = trigger,
        %StochasticSchedule{} = schedule,
        %StochasticScheduleClaim{} = claim,
        %DateTime{} = executed_at,
        random
      ) do
    with :ok <- validate_event(trigger.event),
         {:ok, %Decision{} = decision} <-
           StochasticDueEvaluator.evaluate(trigger, schedule, executed_at),
         :ok <- validate_claim(trigger, schedule, claim, executed_at) do
      build_plan(trigger, claim, executed_at, decision, random)
    end
  end

  def plan(%StochasticTrigger{}, %StochasticSchedule{}, %StochasticScheduleClaim{}, _at, _random),
    do: {:error, :invalid_datetime}

  def plan(%StochasticTrigger{}, %StochasticSchedule{}, _claim, _at, _random),
    do: {:error, :invalid_claim}

  def plan(%StochasticTrigger{}, _schedule, _claim, _at, _random),
    do: {:error, :invalid_schedule}

  def plan(_trigger, _schedule, _claim, _at, _random), do: {:error, :invalid_trigger}

  defp build_plan(_trigger, _claim, _executed_at, %Decision{eligible: false} = decision, _random),
    do: {:skip, decision}

  defp build_plan(
         trigger,
         claim,
         executed_at,
         %Decision{eligible: true, reason: :eligible, local_date: local_date},
         random
       ) do
    case StochasticScheduleCalculator.next_run(trigger, executed_at, random) do
      {:ok, next_run_at} ->
        {:ok,
         %Plan{
           claim: claim,
           event: trigger.event,
           executed_at: executed_at,
           next_run_at: next_run_at,
           local_date: local_date
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_event(%EmittedEvent{type: type, group: group, subject: subject}) do
    if Enum.all?([type, group, subject], &valid_event_id?/1),
      do: :ok,
      else: {:error, :invalid_trigger}
  end

  defp validate_event(_event), do: {:error, :invalid_trigger}

  defp valid_event_id?(value) when is_binary(value) and byte_size(value) <= @max_id_bytes,
    do: match?({:ok, _value}, Value.id(value))

  defp valid_event_id?(_value), do: false

  defp validate_claim(
         %StochasticTrigger{id: trigger_id},
         %StochasticSchedule{trigger_id: trigger_id, next_run_at: expected_next_run_at},
         %StochasticScheduleClaim{
           trigger_id: trigger_id,
           expected_next_run_at: expected_next_run_at,
           token: token,
           started_at: started_at,
           expires_at: expires_at
         },
         executed_at
       ) do
    if valid_claim_token?(token) and valid_storage_datetime?(started_at) and
         valid_storage_datetime?(expires_at) and fixed_lease?(started_at, expires_at) and
         DateTime.compare(expected_next_run_at, started_at) in [:lt, :eq] and
         DateTime.compare(started_at, executed_at) in [:lt, :eq] and
         DateTime.compare(executed_at, expires_at) == :lt do
      :ok
    else
      {:error, :invalid_claim}
    end
  end

  defp validate_claim(_trigger, _schedule, _claim, _executed_at),
    do: {:error, :invalid_claim}

  defp fixed_lease?(started_at, expires_at) do
    started_at
    |> DateTime.add(@claim_lease_seconds, :second)
    |> DateTime.compare(expires_at) == :eq
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_claim_token?(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == @claim_token_bytes
      :error -> false
    end
  end

  defp valid_claim_token?(_token), do: false

  defp valid_storage_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok
end

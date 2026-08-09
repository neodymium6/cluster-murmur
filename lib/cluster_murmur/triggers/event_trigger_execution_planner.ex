defmodule ClusterMurmur.Triggers.EventTriggerExecutionPlanner do
  @moduledoc """
  Plans one matched event-trigger execution without performing side effects.

  The supplied trigger and event are revalidated and matched before cooldown
  policy is evaluated. Returned plans are fully redacted from inspection.
  """

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, MatcherEvaluator, Validator}
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerCooldown, EventTriggerValidator}

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @default_event_policy EventPolicy.default()
    @enforce_keys [:trigger, :event, :executed_at, :cooldown_until]
    defstruct [
      :trigger,
      :event,
      :executed_at,
      :cooldown_until,
      event_policy: @default_event_policy
    ]

    @type t :: %__MODULE__{
            trigger: ClusterMurmur.Triggers.EventTrigger.t(),
            event: ClusterMurmur.Events.Event.t(),
            executed_at: DateTime.t(),
            cooldown_until: DateTime.t(),
            event_policy: ClusterMurmur.Config.EventPolicy.t()
          }
  end

  @type skip_reason :: :cooldown | :not_matched
  @type error ::
          :invalid_datetime
          | :invalid_event
          | :invalid_event_policy
          | :invalid_trigger
          | :invalid_trigger_matcher

  @doc "Returns a redacted execution plan or the factual reason the trigger must be skipped."
  @spec plan(term(), term(), term(), term(), term()) ::
          {:ok, Plan.t()} | {:skip, skip_reason()} | {:error, error()}
  def plan(trigger, event, cooldown_until, executed_at, event_policy \\ EventPolicy.default())

  def plan(
        %EventTrigger{} = trigger,
        %Event{} = event,
        cooldown_until,
        executed_at,
        event_policy
      ) do
    with :ok <- EventTriggerValidator.validate(trigger),
         :ok <- Validator.validate(event),
         :ok <- EventPolicy.validate(event_policy),
         :ok <- DateTimeValidator.validate_storage_utc(executed_at),
         {:ok, matches?} <- MatcherEvaluator.match(trigger.matcher, event) do
      plan_match(matches?, trigger, event, cooldown_until, executed_at, event_policy)
    else
      {:error, :invalid_matcher} -> {:error, :invalid_trigger_matcher}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  def plan(%EventTrigger{} = trigger, _event, _cooldown_until, _executed_at, _event_policy) do
    case EventTriggerValidator.validate(trigger) do
      :ok -> {:error, :invalid_event}
      {:error, _reason} = error -> error
    end
  end

  def plan(_trigger, _event, _cooldown_until, _executed_at, _event_policy),
    do: {:error, :invalid_trigger}

  defp plan_match(false, _trigger, _event, _cooldown_until, _executed_at, _event_policy),
    do: {:skip, :not_matched}

  defp plan_match(true, trigger, event, cooldown_until, executed_at, event_policy) do
    case EventTriggerCooldown.evaluate(trigger, cooldown_until, executed_at) do
      {:ok, {:eligible, next_cooldown_until}} ->
        {:ok,
         %Plan{
           trigger: trigger,
           event: event,
           executed_at: executed_at,
           cooldown_until: next_cooldown_until,
           event_policy: event_policy
         }}

      {:ok, {:skip, :cooldown}} ->
        {:skip, :cooldown}

      {:error, _reason} = error ->
        error
    end
  end
end

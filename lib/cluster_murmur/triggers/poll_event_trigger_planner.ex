defmodule ClusterMurmur.Triggers.PollEventTriggerPlanner do
  @moduledoc """
  Plans bounded event-trigger work from one completed observer poll.

  The planner validates the complete poll and current configuration, selects
  matching event triggers deterministically, and rejects an oversized aggregate
  before any trigger execution is authorized. It performs no persistence or
  action orchestration.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Observers.Poller
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult
  alias ClusterMurmur.Triggers.{EventSelector, EventTrigger}

  defmodule Entry do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:event, :triggers]
    defstruct [:event, :triggers]

    @type t :: %__MODULE__{
            event: ClusterMurmur.Events.Event.t(),
            triggers: [ClusterMurmur.Triggers.EventTrigger.t()]
          }
  end

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: [:event_count, :matched_event_count, :match_count, :executed_at]}
    @enforce_keys [
      :poll_result,
      :executed_at,
      :event_count,
      :matched_event_count,
      :match_count,
      :entries
    ]
    defstruct [
      :poll_result,
      :executed_at,
      :event_count,
      :matched_event_count,
      :match_count,
      :entries
    ]

    @type t :: %__MODULE__{
            poll_result: ClusterMurmur.Observers.Poller.Result.t(),
            executed_at: DateTime.t(),
            event_count: non_neg_integer(),
            matched_event_count: non_neg_integer(),
            match_count: non_neg_integer(),
            entries: [ClusterMurmur.Triggers.PollEventTriggerPlanner.Entry.t()]
          }
  end

  @max_matches 256
  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error ::
          :duplicate_poll_event
          | :invalid_configuration
          | :invalid_datetime
          | :invalid_poll
          | :invalid_poll_trigger_plan
          | :too_many_trigger_matches

  @doc "Builds one bounded deterministic plan without authorizing an action."
  @spec plan(term(), term(), term()) :: {:ok, Plan.t()} | {:error, error()}
  def plan(%PollResult{} = poll_result, %Configuration{} = configuration, executed_at) do
    with :ok <- validate_poll(poll_result),
         :ok <- validate_configuration(configuration),
         :ok <- validate_executed_at(executed_at, poll_result.events),
         :ok <- reject_duplicate_events(poll_result.events, %{}),
         triggers <- event_triggers(configuration),
         {:ok, entries, match_count} <- select_entries(poll_result.events, triggers, [], 0) do
      {:ok,
       %Plan{
         poll_result: poll_result,
         executed_at: executed_at,
         event_count: poll_result.event_count,
         matched_event_count: length(entries),
         match_count: match_count,
         entries: entries
       }}
    else
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_poll_trigger_plan}
    end
  rescue
    _error -> {:error, :invalid_poll_trigger_plan}
  catch
    _kind, _reason -> {:error, :invalid_poll_trigger_plan}
  end

  def plan(%PollResult{}, _configuration, _executed_at),
    do: {:error, :invalid_configuration}

  def plan(_poll_result, %Configuration{}, _executed_at), do: {:error, :invalid_poll}
  def plan(_poll_result, _configuration, _executed_at), do: {:error, :invalid_poll_trigger_plan}

  @doc "Rebuilds a plan from the current poll and configuration before authorization."
  @spec validate(term(), term(), term()) :: :ok | {:error, :invalid_poll_trigger_plan}
  def validate(%Plan{} = plan, poll_result, configuration) do
    with true <- exact_plan?(plan),
         {:ok, expected} <- plan(poll_result, configuration, plan.executed_at),
         true <- plan === expected do
      :ok
    else
      _failure -> {:error, :invalid_poll_trigger_plan}
    end
  rescue
    _error -> {:error, :invalid_poll_trigger_plan}
  catch
    _kind, _reason -> {:error, :invalid_poll_trigger_plan}
  end

  def validate(_plan, _poll_result, _configuration),
    do: {:error, :invalid_poll_trigger_plan}

  defp validate_poll(poll_result) do
    case Poller.validate_result(poll_result) do
      :ok -> :ok
      {:error, :invalid_poll} -> {:error, :invalid_poll}
    end
  end

  defp validate_configuration(configuration) do
    case Configuration.validate(configuration) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_configuration}
    end
  end

  defp validate_executed_at(executed_at, events) do
    with :ok <- DateTimeValidator.validate_storage_utc(executed_at),
         true <- Enum.all?(events, &not_before_event?(executed_at, &1)) do
      :ok
    else
      _failure -> {:error, :invalid_datetime}
    end
  end

  defp not_before_event?(executed_at, %Event{} = event) do
    latest =
      case event.observed_at do
        nil ->
          event.occurred_at

        observed_at ->
          if DateTime.compare(observed_at, event.occurred_at) == :lt,
            do: event.occurred_at,
            else: observed_at
      end

    DateTime.compare(executed_at, latest) in [:eq, :gt]
  end

  defp reject_duplicate_events([], _seen), do: :ok

  defp reject_duplicate_events([%Event{id: id} | events], seen) do
    if Map.has_key?(seen, id),
      do: {:error, :duplicate_poll_event},
      else: reject_duplicate_events(events, Map.put(seen, id, true))
  end

  defp event_triggers(configuration) do
    configuration.triggers.triggers
    |> Map.values()
    |> Enum.filter(&match?(%EventTrigger{}, &1))
  end

  defp select_entries([], _triggers, entries, match_count),
    do: {:ok, Enum.reverse(entries), match_count}

  defp select_entries([event | events], triggers, entries, match_count) do
    case EventSelector.select(triggers, event) do
      {:ok, []} ->
        select_entries(events, triggers, entries, match_count)

      {:ok, selected} ->
        next_count = match_count + length(selected)

        if next_count <= @max_matches,
          do:
            select_entries(
              events,
              triggers,
              [%Entry{event: event, triggers: selected} | entries],
              next_count
            ),
          else: {:error, :too_many_trigger_matches}

      {:error, _reason} ->
        {:error, :invalid_poll_trigger_plan}
    end
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end
end

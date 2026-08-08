defmodule ClusterMurmur.Triggers.EventDispatchPlanner do
  @moduledoc """
  Plans one bounded batch of durable event-dispatch candidates without effects.

  Every candidate is correlated positionally with one restored immutable event
  in strict durable order. Matching against the complete current configuration
  is capped before a later runtime claims or authorizes any entry.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Persistence.EventDispatchCandidate
  alias ClusterMurmur.Triggers.{EventSelector, EventTrigger}

  defmodule Entry do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:candidate, :event, :triggers]
    defstruct [:candidate, :event, :triggers]

    @type t :: %__MODULE__{
            candidate: ClusterMurmur.Persistence.EventDispatchCandidate.t(),
            event: ClusterMurmur.Events.Event.t(),
            triggers: [ClusterMurmur.Triggers.EventTrigger.t()]
          }
  end

  defmodule Plan do
    @moduledoc false

    @derive {
      Inspect,
      only: [:executed_at, :candidate_count, :matched_event_count, :match_count]
    }
    @enforce_keys [
      :executed_at,
      :candidate_count,
      :matched_event_count,
      :match_count,
      :entries
    ]
    defstruct [:executed_at, :candidate_count, :matched_event_count, :match_count, :entries]

    @type t :: %__MODULE__{
            executed_at: DateTime.t(),
            candidate_count: non_neg_integer(),
            matched_event_count: non_neg_integer(),
            match_count: non_neg_integer(),
            entries: [ClusterMurmur.Triggers.EventDispatchPlanner.Entry.t()]
          }
  end

  @max_candidates 100
  @max_matches 256
  @candidate_keys EventDispatchCandidate.__struct__() |> Map.keys()
  @candidate_key_count length(@candidate_keys)
  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error ::
          :invalid_configuration
          | :invalid_datetime
          | :invalid_event
          | :invalid_event_dispatch_plan
          | :too_many_dispatch_candidates
          | :too_many_trigger_matches

  @doc "Builds one deterministic bounded plan before any dispatch claim is taken."
  @spec plan(term(), term(), term(), term()) :: {:ok, Plan.t()} | {:error, error()}
  def plan(candidates, events, %Configuration{} = configuration, executed_at)
      when is_list(candidates) and is_list(events) do
    with :ok <- validate_configuration(configuration),
         :ok <- validate_executed_at(executed_at),
         triggers <- event_triggers(configuration),
         {:ok, entries, candidate_count, matched_event_count, match_count} <-
           build_entries(candidates, events, triggers, executed_at, nil, [], 0, 0, 0) do
      {:ok,
       %Plan{
         executed_at: executed_at,
         candidate_count: candidate_count,
         matched_event_count: matched_event_count,
         match_count: match_count,
         entries: entries
       }}
    else
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_event_dispatch_plan}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_plan}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_plan}
  end

  def plan(_candidates, _events, %Configuration{}, _executed_at),
    do: {:error, :invalid_event_dispatch_plan}

  def plan(_candidates, _events, _configuration, _executed_at),
    do: {:error, :invalid_configuration}

  @doc "Rebuilds one plan against the restored events and current configuration."
  @spec validate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_event_dispatch_plan}
  def validate(%Plan{} = plan, candidates, events, configuration) do
    with true <- exact_plan?(plan),
         {:ok, expected} <- plan(candidates, events, configuration, plan.executed_at),
         true <- plan === expected do
      :ok
    else
      _failure -> {:error, :invalid_event_dispatch_plan}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_plan}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_plan}
  end

  def validate(_plan, _candidates, _events, _configuration),
    do: {:error, :invalid_event_dispatch_plan}

  defp build_entries(
         [],
         [],
         _triggers,
         _executed_at,
         _previous,
         entries,
         count,
         matched,
         matches
       ),
       do: {:ok, Enum.reverse(entries), count, matched, matches}

  defp build_entries(
         [%EventDispatchCandidate{} = candidate | candidates],
         [%Event{} = event | events],
         triggers,
         executed_at,
         previous,
         entries,
         count,
         matched,
         matches
       )
       when count < @max_candidates do
    with :ok <- validate_pair(candidate, event, executed_at, previous),
         {:ok, selected} <- select(triggers, event),
         next_matches = matches + length(selected),
         true <- next_matches <= @max_matches do
      build_entries(
        candidates,
        events,
        triggers,
        executed_at,
        candidate,
        [%Entry{candidate: candidate, event: event, triggers: selected} | entries],
        count + 1,
        if(selected == [], do: matched, else: matched + 1),
        next_matches
      )
    else
      false -> {:error, :too_many_trigger_matches}
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_event_dispatch_plan}
    end
  end

  defp build_entries(
         [%EventDispatchCandidate{} | _candidates],
         [%Event{} | _events],
         _triggers,
         _executed_at,
         _previous,
         _entries,
         @max_candidates,
         _matched,
         _matches
       ),
       do: {:error, :too_many_dispatch_candidates}

  defp build_entries(
         _candidates,
         _events,
         _triggers,
         _executed_at,
         _previous,
         _entries,
         _count,
         _matched,
         _matches
       ),
       do: {:error, :invalid_event_dispatch_plan}

  defp validate_pair(candidate, event, executed_at, previous) do
    with true <- exact_candidate?(candidate),
         :ok <- Validator.validate_id(candidate.event_id),
         :ok <- DateTimeValidator.validate_storage_utc(candidate.enqueued_at),
         true <- DateTime.compare(candidate.enqueued_at, executed_at) in [:lt, :eq],
         true <- after_previous?(candidate, previous),
         :ok <- Validator.validate(event),
         true <- event.id == candidate.event_id,
         true <- not_before_event?(candidate.enqueued_at, event) do
      :ok
    else
      {:error, :invalid_event} -> {:error, :invalid_event}
      _failure -> {:error, :invalid_event_dispatch_plan}
    end
  end

  defp validate_configuration(configuration) do
    case Configuration.validate(configuration) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_configuration}
    end
  end

  defp validate_executed_at(executed_at) do
    case DateTimeValidator.validate_storage_utc(executed_at) do
      :ok -> :ok
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
    end
  end

  defp event_triggers(configuration) do
    configuration.triggers.triggers
    |> Map.values()
    |> Enum.filter(&match?(%EventTrigger{}, &1))
  end

  defp select(triggers, event) do
    case EventSelector.select(triggers, event) do
      {:ok, selected} -> {:ok, selected}
      {:error, _reason} -> {:error, :invalid_event_dispatch_plan}
    end
  end

  defp after_previous?(_candidate, nil), do: true

  defp after_previous?(candidate, previous) do
    case DateTime.compare(candidate.enqueued_at, previous.enqueued_at) do
      :gt -> true
      :eq -> candidate.event_id > previous.event_id
      :lt -> false
    end
  end

  defp not_before_event?(enqueued_at, event) do
    latest =
      case event.observed_at do
        nil -> event.occurred_at
        observed_at -> later(event.occurred_at, observed_at)
      end

    DateTime.compare(enqueued_at, latest) in [:eq, :gt]
  end

  defp later(left, right), do: if(DateTime.compare(left, right) == :lt, do: right, else: left)

  defp exact_candidate?(candidate) do
    map_size(candidate) == @candidate_key_count and
      Enum.all?(@candidate_keys, &Map.has_key?(candidate, &1))
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end
end

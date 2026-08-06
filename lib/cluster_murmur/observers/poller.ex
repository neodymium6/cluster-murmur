defmodule ClusterMurmur.Observers.Poller do
  @moduledoc """
  Runs one bounded, sequential read-only observation poll.

  A poll validates startup-owned debounce settings before calling an injected
  observer, normalizes its target catalog, observes each target once in stable
  order, and delegates accepted observations to the atomic ingestion store. It
  does not schedule another poll, expose transport operations, or execute an
  event trigger.
  """

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.ExternalError

  alias ClusterMurmur.Observations.{
    EntityState,
    EntityStateValidator,
    EventProjector,
    IngestionPlanner,
    Observation
  }

  alias ClusterMurmur.Observers.TargetCatalog
  alias ClusterMurmur.Persistence.ObservationIngestionStore

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:target_count, :ingested_count, :event_count, :failure_count]}
    @enforce_keys [
      :target_count,
      :ingested_count,
      :event_count,
      :failure_count,
      :events,
      :failures
    ]
    defstruct [
      :target_count,
      :ingested_count,
      :event_count,
      :failure_count,
      :events,
      :failures
    ]

    @type failure :: {:observer, ClusterMurmur.ExternalError.t()} | :ingestion_failed

    @type t :: %__MODULE__{
            target_count: non_neg_integer(),
            ingested_count: non_neg_integer(),
            event_count: non_neg_integer(),
            failure_count: non_neg_integer(),
            events: [ClusterMurmur.Events.Event.t()],
            failures: [failure()]
          }
  end

  @external_errors [
    :authentication_failed,
    :invalid_request,
    :invalid_response,
    :rate_limited,
    :timeout,
    :unavailable
  ]
  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)
  @plan_keys IngestionPlanner.Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)
  @max_targets 256

  @type error ::
          :invalid_poll
          | :invalid_observer_targets
          | {:observer, ExternalError.t()}

  @doc "Runs one bounded poll through injected fixed observer and ingestion modules."
  @spec poll_once(module(), term(), module()) :: {:ok, Result.t()} | {:error, error()}
  def poll_once(
        observer_client,
        state_tracking,
        ingestion_store \\ ObservationIngestionStore
      )

  def poll_once(observer_client, state_tracking, ingestion_store)
      when is_atom(observer_client) and is_atom(ingestion_store) do
    with {:ok, policy} <- StateTracking.to_debounce_policy(state_tracking),
         :ok <- validate_dependencies(observer_client, ingestion_store),
         {:ok, raw_targets} <- list_targets(observer_client),
         {:ok, catalog} <- TargetCatalog.parse(raw_targets),
         {:ok, result} <- poll_targets(catalog.targets, observer_client, ingestion_store, policy),
         :ok <- validate_result(result) do
      {:ok, result}
    else
      {:error, :invalid_state_tracking_configuration} -> {:error, :invalid_poll}
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_poll}
    end
  rescue
    _error -> {:error, :invalid_poll}
  catch
    _kind, _reason -> {:error, :invalid_poll}
  end

  def poll_once(_observer_client, _state_tracking, _ingestion_store),
    do: {:error, :invalid_poll}

  @doc "Revalidates one exact redacted poll result before event dispatch."
  @spec validate_result(term()) :: :ok | {:error, :invalid_poll}
  def validate_result(%Result{} = result) do
    with true <- exact_result?(result),
         true <- valid_count_values?(result),
         {:ok, event_count} <- validate_events(result.events, 0),
         {:ok, failure_count} <- validate_failures(result.failures, 0),
         true <- valid_count_relations?(result, event_count, failure_count) do
      :ok
    else
      _failure -> {:error, :invalid_poll}
    end
  rescue
    _error -> {:error, :invalid_poll}
  catch
    _kind, _reason -> {:error, :invalid_poll}
  end

  def validate_result(_result), do: {:error, :invalid_poll}

  defp validate_dependencies(observer_client, ingestion_store) do
    if Code.ensure_loaded?(observer_client) and Code.ensure_loaded?(ingestion_store) and
         function_exported?(observer_client, :list_targets, 0) and
         function_exported?(observer_client, :observe_target, 1) and
         function_exported?(ingestion_store, :ingest, 2),
       do: :ok,
       else: {:error, :invalid_poll}
  end

  defp list_targets(observer_client) do
    case observer_client.list_targets() do
      {:ok, targets} -> {:ok, targets}
      {:error, reason} when reason in @external_errors -> {:error, {:observer, reason}}
      _failure -> {:error, {:observer, :invalid_response}}
    end
  rescue
    _error -> {:error, {:observer, :unavailable}}
  catch
    _kind, _reason -> {:error, {:observer, :unavailable}}
  end

  defp poll_targets(targets, observer_client, ingestion_store, policy) do
    targets
    |> Enum.reduce({0, [], []}, fn target, {ingested, events, failures} ->
      case observe_and_ingest(target.id, observer_client, ingestion_store, policy) do
        {:ok, nil} -> {ingested + 1, events, failures}
        {:ok, %Event{} = event} -> {ingested + 1, [event | events], failures}
        {:error, failure} -> {ingested, events, [failure | failures]}
      end
    end)
    |> then(fn {ingested, events, failures} ->
      events = Enum.reverse(events)
      failures = Enum.reverse(failures)

      {:ok,
       %Result{
         target_count: length(targets),
         ingested_count: ingested,
         event_count: length(events),
         failure_count: length(failures),
         events: events,
         failures: failures
       }}
    end)
  end

  defp observe_and_ingest(target_id, observer_client, ingestion_store, policy) do
    with {:ok, observation} <- observe_target(observer_client, target_id),
         :ok <- validate_observation_target(observation, target_id),
         {:ok, plan} <- ingest(ingestion_store, observation, policy) do
      {:ok, plan.event}
    end
  end

  defp observe_target(observer_client, target_id) do
    case observer_client.observe_target(target_id) do
      {:ok, %Observation{} = observation} -> {:ok, observation}
      {:error, reason} when reason in @external_errors -> {:error, {:observer, reason}}
      _failure -> {:error, {:observer, :invalid_response}}
    end
  rescue
    _error -> {:error, {:observer, :unavailable}}
  catch
    _kind, _reason -> {:error, {:observer, :unavailable}}
  end

  defp validate_observation_target(observation, target_id) do
    if ClusterMurmur.Observations.Validator.validate(observation) == :ok and
         observation.subject == target_id,
       do: :ok,
       else: {:error, {:observer, :invalid_response}}
  end

  defp ingest(ingestion_store, observation, policy) do
    case ingestion_store.ingest(observation, policy) do
      {:ok, %IngestionPlanner.Plan{} = plan} ->
        if valid_plan?(plan, observation, policy),
          do: {:ok, plan},
          else: {:error, :ingestion_failed}

      _failure ->
        {:error, :ingestion_failed}
    end
  rescue
    _error -> {:error, :ingestion_failed}
  catch
    _kind, _reason -> {:error, :ingestion_failed}
  end

  defp valid_plan?(plan, observation, policy) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1)) and
      EntityStateValidator.validate(plan.entity_state) == :ok and
      correlated_entity_state?(plan.entity_state, observation, policy) and
      valid_projected_event?(plan.event, plan.entity_state)
  end

  defp correlated_entity_state?(state, observation, policy) do
    state.source === observation.source and state.subject === observation.subject and
      DateTime.compare(state.last_observed_at, observation.observed_at) == :eq and
      state.facts === observation.facts and state.labels === observation.labels and
      correlated_observed_state?(state, observation.state, policy)
  end

  defp correlated_observed_state?(%EntityState{} = state, observed_state, policy) do
    cond do
      state.current_state == observed_state and state.pending_state == nil and
          state.consecutive_count == 0 ->
        true

      state.pending_state == observed_state ->
        state.consecutive_count < threshold(policy, observed_state)

      true ->
        false
    end
  end

  defp threshold(policy, :healthy), do: policy.healthy_threshold
  defp threshold(policy, :unhealthy), do: policy.unhealthy_threshold

  defp valid_projected_event?(nil, %EntityState{last_changed_at: nil}), do: true

  defp valid_projected_event?(nil, %EntityState{} = state),
    do: DateTime.compare(state.last_changed_at, state.last_observed_at) == :lt

  defp valid_projected_event?(%Event{} = event, state) do
    with :ok <- Validator.validate(event),
         {:ok, previous} <- projected_previous(event.previous, state),
         {:ok, projected} <- EventProjector.project(previous, state) do
      projected === event
    else
      _failure -> false
    end
  end

  defp valid_projected_event?(_event, _state), do: false

  defp projected_previous("unknown", _state), do: {:ok, nil}

  defp projected_previous(previous, state) when previous in ["healthy", "unhealthy"] do
    previous_observed_at = DateTime.add(state.last_observed_at, -1, :microsecond)

    {:ok,
     %EntityState{
       source: state.source,
       subject: state.subject,
       current_state: String.to_existing_atom(previous),
       pending_state: nil,
       consecutive_count: 0,
       last_observed_at: previous_observed_at,
       last_changed_at: previous_observed_at,
       facts: state.facts,
       labels: state.labels
     }}
  end

  defp projected_previous(_previous, _state), do: {:error, :invalid_projection}

  defp exact_result?(result) do
    map_size(result) == @result_key_count and Enum.all?(@result_keys, &Map.has_key?(result, &1))
  end

  defp valid_count_values?(result) do
    counts = [
      result.target_count,
      result.ingested_count,
      result.event_count,
      result.failure_count
    ]

    Enum.all?(counts, &(is_integer(&1) and &1 in 0..@max_targets))
  end

  defp valid_count_relations?(result, event_count, failure_count) do
    result.target_count == result.ingested_count + result.failure_count and
      result.event_count <= result.ingested_count and result.event_count == event_count and
      result.failure_count == failure_count
  end

  defp validate_events([], count), do: {:ok, count}

  defp validate_events([%Event{} = event | events], count) when count < @max_targets do
    if Validator.validate(event) == :ok,
      do: validate_events(events, count + 1),
      else: {:error, :invalid_poll}
  end

  defp validate_events(_events, _count), do: {:error, :invalid_poll}

  defp validate_failures([], count), do: {:ok, count}

  defp validate_failures([{:observer, reason} | failures], count)
       when count < @max_targets and reason in @external_errors,
       do: validate_failures(failures, count + 1)

  defp validate_failures([:ingestion_failed | failures], count) when count < @max_targets,
    do: validate_failures(failures, count + 1)

  defp validate_failures(_failures, _count), do: {:error, :invalid_poll}
end

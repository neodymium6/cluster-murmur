defmodule ClusterMurmur.Observations.IngestionPlanner do
  @moduledoc """
  Purely plans one normalized observation ingestion step.

  The plan combines the next durable entity state with an optional factual
  event. It performs no reads, writes, observer calls, or trigger execution.
  """

  alias ClusterMurmur.Events.Event

  alias ClusterMurmur.Observations.{
    DebounceEvaluator,
    DebouncePolicy,
    EntityState,
    EventProjector,
    Observation
  }

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:entity_state, :event]
    defstruct [:entity_state, :event]

    @type t :: %__MODULE__{
            entity_state: ClusterMurmur.Observations.EntityState.t(),
            event: ClusterMurmur.Events.Event.t() | nil
          }
  end

  @type error ::
          DebounceEvaluator.error()
          | :invalid_observation_transition

  @doc "Returns the next state and optional event for one validated observation."
  @spec plan(EntityState.t() | nil, Observation.t(), DebouncePolicy.t()) ::
          {:ok, Plan.t()} | {:error, error()}
  def plan(previous, observation, policy) do
    with {:ok, next} <- DebounceEvaluator.evaluate(previous, observation, policy),
         {:ok, event} <- project_optional_event(previous, next) do
      {:ok, %Plan{entity_state: next, event: event}}
    end
  end

  defp project_optional_event(previous, next) do
    case EventProjector.project(previous, next) do
      {:ok, %Event{} = event} -> {:ok, event}
      :no_event -> {:ok, nil}
      {:error, :invalid_observation_transition} = error -> error
    end
  end
end

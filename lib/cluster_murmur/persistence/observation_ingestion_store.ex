defmodule ClusterMurmur.Persistence.ObservationIngestionStore do
  @moduledoc """
  Atomically plans and persists one normalized observation.

  The store restores only the observation's entity identity, delegates factual
  debounce and event decisions to the pure ingestion planner, and commits the
  next state with its optional event in one repository transaction. It does not
  call an observer, apply event dedupe policy, or execute triggers.
  """

  alias ClusterMurmur.Observations.{IngestionPlanner, Observation}

  alias ClusterMurmur.Persistence.{
    EntityStateStore,
    EventStore
  }

  alias ClusterMurmur.Repo

  @known_errors [
    :entity_state_conflict,
    :event_conflict,
    :invalid_debounce_policy,
    :invalid_entity_identity,
    :invalid_entity_state,
    :invalid_entity_state_record,
    :invalid_event,
    :invalid_event_record,
    :invalid_observation,
    :invalid_observation_transition,
    :observation_identity_mismatch,
    :stale_observation,
    :storage_unavailable
  ]

  @type error ::
          IngestionPlanner.error()
          | EntityStateStore.error()
          | EventStore.error()

  @doc "Commits one next entity state and its optional event atomically."
  @spec ingest(term(), term()) :: {:ok, IngestionPlanner.Plan.t()} | {:error, error()}
  def ingest(observation, policy) do
    with {:ok, _preflight} <- IngestionPlanner.plan(nil, observation, policy) do
      observation
      |> persist_transaction(policy)
      |> normalize_transaction()
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp persist_transaction(%Observation{} = observation, policy) do
    Repo.transaction(fn -> transact(observation, policy) end)
  end

  defp transact(observation, policy) do
    with {:ok, previous} <- EntityStateStore.fetch(observation.source, observation.subject),
         {:ok, plan} <- IngestionPlanner.plan(previous, observation, policy),
         {:ok, _state_record} <- EntityStateStore.put(plan.entity_state),
         :ok <- persist_event(plan.event) do
      plan
    else
      {:error, reason} -> Repo.rollback(reason)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp persist_event(nil), do: :ok

  defp persist_event(event) do
    case EventStore.insert(event) do
      {:ok, _event_record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_transaction({:ok, %IngestionPlanner.Plan{} = plan}), do: {:ok, plan}

  defp normalize_transaction({:error, reason}) when reason in @known_errors,
    do: {:error, reason}

  defp normalize_transaction(_failure), do: {:error, :storage_unavailable}
end

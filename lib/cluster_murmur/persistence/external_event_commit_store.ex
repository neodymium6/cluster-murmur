defmodule ClusterMurmur.Persistence.ExternalEventCommitStore do
  @moduledoc """
  Atomically commits one normalized external event and dispatch handoff.

  An exact retry restores the first durable event and outbox receipt, including
  its original enqueue time and current lifecycle status. Reusing an identity
  for changed content or finding a partial durable pair fails closed.
  """

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Ingestion.{EventEnvelope, EventProjector}

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventDispatchStore,
    EventRecord,
    EventStore
  }

  alias ClusterMurmur.Repo

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:duplicate?]}
    @enforce_keys [:event, :dispatch, :duplicate?]
    defstruct [:event, :dispatch, :duplicate?]

    @type t :: %__MODULE__{
            event: ClusterMurmur.Persistence.EventRecord.t(),
            dispatch: ClusterMurmur.Persistence.EventDispatchReceipt.t(),
            duplicate?: boolean()
          }
  end

  @event_fields Event.__struct__() |> Map.keys()

  @type error ::
          :external_event_conflict
          | :invalid_external_event_commit
          | :storage_unavailable

  @doc "Commits or restores one exact external event and its dispatch atomically."
  @spec commit(term(), term(), term()) :: {:ok, Result.t()} | {:error, error()}
  def commit(
        %EventEnvelope{} = envelope,
        %ExternalIngestion{} = configuration,
        %DateTime{} = accepted_at
      ) do
    with {:ok, event} <- EventProjector.project(envelope, configuration),
         :ok <- DateTimeValidator.validate_storage_utc(accepted_at),
         true <- DateTime.compare(accepted_at, event.occurred_at) in [:eq, :gt] do
      persist(event, accepted_at)
    else
      _failure -> {:error, :invalid_external_event_commit}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def commit(_envelope, _configuration, _accepted_at),
    do: {:error, :invalid_external_event_commit}

  defp persist(event, accepted_at) do
    case Repo.transaction(fn -> persist_transaction(event, accepted_at) end, mode: :immediate) do
      {:ok, {%EventRecord{} = record, %EventDispatchReceipt{} = dispatch, duplicate?}} ->
        {:ok, %Result{event: record, dispatch: dispatch, duplicate?: duplicate?}}

      {:error, reason}
      when reason in [:external_event_conflict, :invalid_external_event_commit] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp persist_transaction(event, accepted_at) do
    case EventStore.fetch(event.id) do
      {:error, :event_not_found} -> commit_new(event, accepted_at)
      {:ok, existing} -> restore_existing(existing, event)
      {:error, :invalid_event_record} -> Repo.rollback(:external_event_conflict)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end

  defp commit_new(event, accepted_at) do
    with {:ok, %EventRecord{} = record} <- insert_event(event),
         {:ok, %EventDispatchReceipt{status: :pending} = dispatch} <-
           enqueue_event(event, accepted_at) do
      {record, dispatch, false}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp restore_existing(existing, event) do
    if identical_event?(existing, event) do
      with {:ok, %EventRecord{} = record} <- insert_event(event),
           {:ok, %EventDispatchReceipt{} = dispatch} <- EventDispatchStore.fetch_receipt(event) do
        {record, dispatch, true}
      else
        {:error, :storage_unavailable} -> Repo.rollback(:storage_unavailable)
        _failure -> Repo.rollback(:external_event_conflict)
      end
    else
      Repo.rollback(:external_event_conflict)
    end
  end

  defp insert_event(event) do
    case EventStore.insert(event) do
      {:ok, %EventRecord{} = record} -> {:ok, record}
      {:error, :event_conflict} -> {:error, :external_event_conflict}
      {:error, :invalid_event} -> {:error, :invalid_external_event_commit}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp enqueue_event(event, accepted_at) do
    case EventDispatchStore.enqueue(event, accepted_at) do
      {:ok, %EventDispatchReceipt{status: :pending} = dispatch} ->
        {:ok, dispatch}

      {:error, reason} when reason in [:dispatch_conflict, :event_conflict] ->
        {:error, :external_event_conflict}

      {:error, reason} when reason in [:invalid_datetime, :invalid_dispatch, :invalid_event] ->
        {:error, :invalid_external_event_commit}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp identical_event?(left, right),
    do: Map.take(left, @event_fields) === Map.take(right, @event_fields)
end

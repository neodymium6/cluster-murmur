defmodule ClusterMurmur.Persistence.TriggerExecutionStore do
  @moduledoc """
  Atomically starts one validated event-trigger execution.

  The transaction requires the immutable event to be committed unchanged,
  rejects a previously started trigger/event pair, and rechecks the latest
  durable cooldown before inserting a started record. It never runs the action.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Persistence.{EventStore, TriggerExecution}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan

  @type error ::
          :event_conflict
          | :event_not_found
          | :execution_conflict
          | :invalid_execution
          | :storage_unavailable

  @doc "Starts one plan when its event, deduplication key, and durable cooldown permit it."
  @spec start(term()) ::
          {:ok, TriggerExecution.t()} | {:skip, :cooldown} | {:error, error()}
  def start(plan) do
    changeset = TriggerExecution.start_changeset(%TriggerExecution{}, plan)

    if changeset.valid? do
      persist_start(changeset, plan)
    else
      {:error, :invalid_execution}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp persist_start(changeset, %Plan{} = plan) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    case Repo.transaction(fn -> start_transaction(changeset, candidate, plan) end) do
      {:ok, %TriggerExecution{} = execution} ->
        {:ok, execution}

      {:error, {:skip, :cooldown}} ->
        {:skip, :cooldown}

      {:error, reason}
      when reason in [:event_conflict, :event_not_found, :execution_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp start_transaction(changeset, candidate, plan) do
    with :ok <- require_identical_event(plan),
         :ok <- reject_existing_pair(candidate),
         :ok <- require_expired_cooldown(candidate),
         {:ok, %TriggerExecution{} = execution} <- Repo.insert(changeset) do
      execution
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp require_identical_event(%Plan{} = plan) do
    case EventStore.fetch(plan.event.id) do
      {:ok, event} when event == plan.event -> :ok
      {:ok, _different_event} -> {:error, :event_conflict}
      {:error, :event_not_found} -> {:error, :event_not_found}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp reject_existing_pair(candidate) do
    case Repo.get_by(TriggerExecution,
           trigger_id: candidate.trigger_id,
           event_id: candidate.event_id
         ) do
      nil -> :ok
      %TriggerExecution{} -> {:error, :execution_conflict}
    end
  end

  defp require_expired_cooldown(candidate) do
    query =
      from execution in TriggerExecution,
        where: execution.trigger_id == ^candidate.trigger_id,
        order_by: [desc: execution.cooldown_until, desc: execution.executed_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        :ok

      %TriggerExecution{cooldown_until: cooldown_until} ->
        if DateTime.compare(cooldown_until, candidate.executed_at) == :gt,
          do: {:error, {:skip, :cooldown}},
          else: :ok
    end
  end
end

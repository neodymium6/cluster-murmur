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

  @event_identity_fields [
    :id,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :previous,
    :current,
    :dedupe_key,
    :correlation_key,
    :facts,
    :labels
  ]

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
      {:ok, event} ->
        if identical_event?(event, plan.event), do: :ok, else: {:error, :event_conflict}

      {:error, :event_not_found} ->
        {:error, :event_not_found}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp identical_event?(persisted, planned) do
    Map.take(persisted, @event_identity_fields) == Map.take(planned, @event_identity_fields) and
      same_datetime?(persisted.occurred_at, planned.occurred_at) and
      same_optional_datetime?(persisted.observed_at, planned.observed_at)
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp same_optional_datetime?(nil, nil), do: true
  defp same_optional_datetime?(left, right), do: same_datetime?(left, right)

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

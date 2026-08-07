defmodule ClusterMurmur.Persistence.EventTriggerConversationActionStore do
  @moduledoc """
  Atomically consumes one authorized event-trigger conversation action.

  The transaction starts the pristine conversation and compare-and-set
  completes the exact durable trigger execution. A stale or previously consumed
  authorization cannot create another conversation, including under a different
  conversation ID.
  """

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationStore,
    TriggerExecution,
    TriggerExecutionStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer
  alias ClusterMurmur.Triggers.EventTriggerConversationPlanner.Plan

  @type error ::
          :conversation_conflict
          | :event_not_found
          | :execution_conflict
          | :invalid_conversation
          | :invalid_conversation_record
          | :invalid_execution
          | :storage_unavailable

  @doc "Starts the planned conversation and consumes its exact authorization once."
  @spec consume(term()) ::
          {:ok, {ConversationRecord.t(), TriggerExecution.t()}} | {:error, error()}
  def consume(%Plan{} = plan) do
    with :ok <- EventTriggerAuthorizer.validate(plan.authorization) do
      transact(plan)
    else
      _failure -> {:error, :invalid_execution}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def consume(_plan), do: {:error, :invalid_execution}

  defp transact(plan) do
    case Repo.transaction(fn -> consume_transaction(plan) end) do
      {:ok, {%ConversationRecord{}, %TriggerExecution{}} = result} ->
        {:ok, result}

      {:error, reason}
      when reason in [
             :conversation_conflict,
             :event_not_found,
             :execution_conflict,
             :invalid_conversation,
             :invalid_conversation_record,
             :invalid_execution
           ] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp consume_transaction(plan) do
    with {:ok, %ConversationRecord{} = conversation} <-
           ConversationStore.start(plan.conversation),
         {:ok, %TriggerExecution{} = execution} <-
           TriggerExecutionStore.complete(plan.authorization.execution) do
      {conversation, execution}
    else
      {:error, reason} -> Repo.rollback(reason)
      _failure -> Repo.rollback(:storage_unavailable)
    end
  end
end

defmodule ClusterMurmur.Triggers.EventTriggerConversationStarter do
  @moduledoc """
  Starts one authorized event-trigger conversation through a narrow store.

  The boundary revalidates the complete conversation plan against current
  configuration and cooldown facts, delegates only pristine persistence to the
  injected store, and returns a redacted capability correlated with the exact
  loaded conversation record. It does not generate, publish, or finish the
  trigger execution.
  """

  alias ClusterMurmur.Config.Configuration

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    EventTriggerConversationActionStore,
    TriggerExecution,
    TriggerExecutionValidator
  }

  alias ClusterMurmur.Triggers.EventTriggerConversationPlanner
  alias ClusterMurmur.Triggers.EventTriggerConversationPlanner.Plan

  defmodule Started do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:plan, :conversation, :execution]
    defstruct [:plan, :conversation, :execution]

    @type t :: %__MODULE__{
            plan: ClusterMurmur.Triggers.EventTriggerConversationPlanner.Plan.t(),
            conversation: ClusterMurmur.Persistence.ConversationRecord.t(),
            execution: ClusterMurmur.Persistence.TriggerExecution.t()
          }
  end

  @started_keys Started.__struct__() |> Map.keys()
  @started_key_count length(@started_keys)

  @type error ::
          :conversation_conflict
          | :event_not_found
          | :execution_conflict
          | :invalid_conversation_plan
          | :invalid_conversation_record
          | :invalid_execution
          | :storage_unavailable

  @doc "Revalidates and persists one pristine authorized conversation plan."
  @spec start(term(), term(), term(), module()) :: {:ok, Started.t()} | {:error, error()}
  def start(plan, configuration, cooldowns, store \\ EventTriggerConversationActionStore)

  def start(%Plan{} = plan, %Configuration{} = configuration, cooldowns, store)
      when is_atom(store) do
    with :ok <- EventTriggerConversationPlanner.validate_plan(plan, configuration, cooldowns),
         :ok <- validate_store(store),
         {:ok, {conversation, execution}} <- persist(store, plan),
         :ok <- validate_store_result(conversation, execution, plan),
         started = %Started{plan: plan, conversation: conversation, execution: execution},
         :ok <- validate(started, configuration, cooldowns) do
      {:ok, started}
    else
      {:error, reason}
      when reason in [
             :conversation_conflict,
             :event_not_found,
             :execution_conflict,
             :invalid_conversation_plan,
             :invalid_conversation_record,
             :invalid_execution,
             :storage_unavailable
           ] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  def start(_plan, _configuration, _cooldowns, _store),
    do: {:error, :invalid_conversation_plan}

  @doc "Revalidates one exact started capability against current bounded facts."
  @spec validate(term(), term(), term()) :: :ok | {:error, :invalid_conversation_plan}
  def validate(%Started{} = started, %Configuration{} = configuration, cooldowns) do
    if exact_started?(started) and
         EventTriggerConversationPlanner.validate_plan(started.plan, configuration, cooldowns) ==
           :ok and
         correlated_conversation?(started.conversation, started.plan) and
         correlated_execution?(started.execution, started.plan) do
      :ok
    else
      {:error, :invalid_conversation_plan}
    end
  rescue
    _error -> {:error, :invalid_conversation_plan}
  catch
    _kind, _reason -> {:error, :invalid_conversation_plan}
  end

  def validate(_started, _configuration, _cooldowns),
    do: {:error, :invalid_conversation_plan}

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :consume, 1),
      do: :ok,
      else: {:error, :storage_unavailable}
  end

  defp persist(store, plan) do
    case store.consume(plan) do
      {:ok, {%ConversationRecord{} = conversation, %TriggerExecution{} = execution}} ->
        {:ok, {conversation, execution}}

      {:error, reason} ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp validate_store_result(conversation, execution, plan) do
    cond do
      not correlated_conversation?(conversation, plan) ->
        {:error, :invalid_conversation_record}

      not correlated_execution?(execution, plan) ->
        {:error, :invalid_execution}

      true ->
        :ok
    end
  end

  defp correlated_conversation?(conversation, plan) do
    ConversationRecordValidator.validate_started(conversation) == :ok and
      conversation.id === plan.conversation.id and
      conversation.root_event_id === plan.conversation.root_event_id and
      conversation.status === :starting and conversation.turn_count === 0 and
      conversation.llm_call_count === 0 and
      same_datetime?(conversation.started_at, plan.conversation.started_at) and
      is_nil(conversation.completed_at)
  end

  defp correlated_execution?(execution, plan) do
    authorized = plan.authorization.execution

    TriggerExecutionValidator.validate(execution) == :ok and
      execution.status === :completed and is_nil(execution.error_class) and
      execution.trigger_id === authorized.trigger_id and
      execution.event_id === authorized.event_id and
      same_datetime?(execution.executed_at, authorized.executed_at) and
      same_datetime?(execution.cooldown_until, authorized.cooldown_until)
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp exact_started?(started) do
    map_size(started) == @started_key_count and
      Enum.all?(@started_keys, &Map.has_key?(started, &1))
  end
end

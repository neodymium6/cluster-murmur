defmodule ClusterMurmur.Runtime.Recovery do
  @moduledoc """
  Closes bounded abandoned runtime work without retrying external effects.

  Every collection is loaded and validated before the first mutation. Started
  or dispatching publication attempts become ambiguous, active conversations
  become failed, and started trigger executions become failed. Recovery never
  regenerates content, republishes a message, or reauthorizes an event.
  """

  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    ConversationStore,
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator,
    PublicationAttemptStore,
    TriggerExecution,
    TriggerExecutionValidator,
    TriggerExecutionStore
  }

  defmodule Stores do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:executions, :conversations, :publications]
    defstruct [:executions, :conversations, :publications]

    @type t :: %__MODULE__{
            executions: module(),
            conversations: module(),
            publications: module()
          }
  end

  defmodule Result do
    @moduledoc false

    @derive {Inspect,
             only: [
               :execution_count,
               :conversation_count,
               :publication_count,
               :failure_count
             ]}
    @enforce_keys [
      :execution_count,
      :conversation_count,
      :publication_count,
      :failure_count
    ]
    defstruct [:execution_count, :conversation_count, :publication_count, :failure_count]

    @type t :: %__MODULE__{
            execution_count: non_neg_integer(),
            conversation_count: non_neg_integer(),
            publication_count: non_neg_integer(),
            failure_count: non_neg_integer()
          }
  end

  @store_keys Stores.__struct__() |> Map.keys()
  @store_key_count length(@store_keys)

  @doc "Recovers abandoned work through the fixed durable stores."
  @spec run(term(), term()) :: {:ok, Result.t()} | {:error, :invalid_runtime_recovery}
  def run(cutoff, recovered_at) do
    run(
      cutoff,
      recovered_at,
      %Stores{
        executions: TriggerExecutionStore,
        conversations: ConversationStore,
        publications: PublicationAttemptStore
      }
    )
  end

  @doc false
  @spec run(term(), term(), term()) :: {:ok, Result.t()} | {:error, :invalid_runtime_recovery}
  def run(cutoff, recovered_at, %Stores{} = stores) do
    with :ok <- preflight(cutoff, recovered_at, stores),
         {:ok, executions} <- stores.executions.list_started_before(cutoff),
         {:ok, conversations} <- stores.conversations.list_active_before(cutoff),
         {:ok, publications} <- stores.publications.list_open_before(cutoff),
         :ok <- validate_executions(executions, cutoff),
         :ok <- validate_conversations(conversations, cutoff),
         :ok <- validate_publications(publications, cutoff) do
      {publication_count, publication_failures} =
        recover_each(publications, &stores.publications.mark_ambiguous(&1, recovered_at))

      {conversation_count, conversation_failures} =
        recover_each(conversations, &stores.conversations.fail(&1, recovered_at))

      {execution_count, execution_failures} =
        recover_each(executions, &stores.executions.fail_abandoned(&1, cutoff))

      {:ok,
       %Result{
         execution_count: execution_count,
         conversation_count: conversation_count,
         publication_count: publication_count,
         failure_count: publication_failures + conversation_failures + execution_failures
       }}
    else
      _failure -> {:error, :invalid_runtime_recovery}
    end
  rescue
    _error -> {:error, :invalid_runtime_recovery}
  catch
    _kind, _reason -> {:error, :invalid_runtime_recovery}
  end

  def run(_cutoff, _recovered_at, _stores), do: {:error, :invalid_runtime_recovery}

  defp preflight(cutoff, recovered_at, stores) do
    with true <- exact_stores?(stores),
         :ok <- DateTimeValidator.validate_storage_utc(cutoff),
         :ok <- DateTimeValidator.validate_storage_utc(recovered_at),
         true <- DateTime.compare(recovered_at, cutoff) in [:eq, :gt],
         :ok <- validate_store(stores.executions, list_started_before: 1, fail_abandoned: 2),
         :ok <- validate_store(stores.conversations, list_active_before: 1, fail: 2),
         :ok <- validate_store(stores.publications, list_open_before: 1, mark_ambiguous: 2) do
      :ok
    else
      _failure -> {:error, :invalid_runtime_recovery}
    end
  end

  defp validate_store(store, callbacks) do
    if is_atom(store) and Code.ensure_loaded?(store) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(store, name, arity) end),
       do: :ok,
       else: {:error, :invalid_runtime_recovery}
  end

  defp recover_each(values, operation) when is_list(values) do
    Enum.reduce(values, {0, 0}, fn value, {recovered, failures} ->
      case recover_one(operation, value) do
        {:ok, _terminal} -> {recovered + 1, failures}
        _failure -> {recovered, failures + 1}
      end
    end)
  end

  defp recover_one(operation, value) do
    operation.(value)
  rescue
    _error -> {:error, :recovery_failed}
  catch
    _kind, _reason -> {:error, :recovery_failed}
  end

  defp validate_collection(values, validator) when is_list(values) do
    values
    |> Enum.reduce_while(0, fn value, count ->
      cond do
        count >= 100 -> {:halt, :invalid}
        validator.(value) -> {:cont, count + 1}
        true -> {:halt, :invalid}
      end
    end)
    |> case do
      :invalid -> {:error, :invalid_runtime_recovery}
      _count -> :ok
    end
  end

  defp validate_collection(_values, _validator), do: {:error, :invalid_runtime_recovery}

  defp validate_executions(executions, cutoff) do
    validate_collection(executions, fn
      %TriggerExecution{status: :started, executed_at: executed_at} = execution ->
        TriggerExecutionValidator.validate(execution) == :ok and
          DateTime.compare(executed_at, cutoff) in [:lt, :eq]

      _execution ->
        false
    end)
  end

  defp validate_conversations(conversations, cutoff) do
    validate_collection(conversations, fn
      %ConversationRecord{started_at: started_at} = conversation ->
        ConversationRecordValidator.validate_active(conversation) == :ok and
          DateTime.compare(started_at, cutoff) in [:lt, :eq]

      _conversation ->
        false
    end)
  end

  defp validate_publications(publications, cutoff) do
    validate_collection(publications, fn
      %PublicationAttemptRecord{status: status, started_at: started_at} = publication
      when status in [:started, :dispatching] ->
        PublicationAttemptRecordValidator.validate(publication) == :ok and
          DateTime.compare(started_at, cutoff) in [:lt, :eq]

      _publication ->
        false
    end)
  end

  defp exact_stores?(stores) do
    map_size(stores) == @store_key_count and Enum.all?(@store_keys, &Map.has_key?(stores, &1))
  end
end

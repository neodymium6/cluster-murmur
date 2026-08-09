defmodule ClusterMurmur.Triggers.EventTriggerAuthorizer do
  @moduledoc """
  Durably authorizes one matched event-trigger execution.

  The boundary builds one pure execution plan without a speculative cooldown
  read, then delegates the final event identity, duplicate-pair, and durable
  cooldown checks to an injected narrow store. It returns only a redacted
  started capability for later action orchestration and performs no action.
  """

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.Persistence.{TriggerExecution, TriggerExecutionStore}
  alias ClusterMurmur.Persistence.TriggerExecutionValidator
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan

  defmodule Authorization do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:plan, :execution]
    defstruct [:plan, :execution]

    @type t :: %__MODULE__{
            plan: ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan.t(),
            execution: ClusterMurmur.Persistence.TriggerExecution.t()
          }
  end

  @authorization_keys Authorization.__struct__() |> Map.keys()
  @authorization_key_count length(@authorization_keys)
  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type skip_reason ::
          :already_terminal | :cooldown | :dedupe_window | :execution_in_progress | :not_matched
  @type error ::
          :event_conflict
          | :event_not_found
          | :invalid_authorization
          | :invalid_datetime
          | :invalid_event
          | :invalid_event_policy
          | :invalid_execution
          | :invalid_trigger
          | :invalid_trigger_matcher
          | :storage_unavailable

  @doc "Plans and durably starts one trigger without executing its action."
  @spec authorize(term(), term(), term(), term()) ::
          {:ok, Authorization.t()} | {:skip, skip_reason()} | {:error, error()}
  def authorize(trigger, event, executed_at),
    do: authorize(trigger, event, executed_at, EventPolicy.default(), TriggerExecutionStore)

  def authorize(trigger, event, executed_at, %EventPolicy{} = event_policy),
    do: authorize(trigger, event, executed_at, event_policy, TriggerExecutionStore)

  def authorize(trigger, event, executed_at, store) when is_atom(store) do
    authorize(trigger, event, executed_at, EventPolicy.default(), store)
  end

  def authorize(_trigger, _event, _executed_at, _store),
    do: {:error, :invalid_authorization}

  @spec authorize(term(), term(), term(), term(), term()) ::
          {:ok, Authorization.t()} | {:skip, skip_reason()} | {:error, error()}
  def authorize(trigger, event, executed_at, event_policy, store) when is_atom(store) do
    case EventTriggerExecutionPlanner.plan(trigger, event, nil, executed_at, event_policy) do
      {:ok, %Plan{} = plan} -> authorize_plan(plan, store)
      {:skip, :not_matched} = skip -> skip
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_authorization}
    end
  rescue
    _error -> {:error, :invalid_authorization}
  catch
    _kind, _reason -> {:error, :invalid_authorization}
  end

  def authorize(_trigger, _event, _executed_at, _event_policy, _store),
    do: {:error, :invalid_authorization}

  @doc "Revalidates one exact redacted authorization before action orchestration."
  @spec validate(term()) :: :ok | {:error, :invalid_authorization}
  def validate(%Authorization{} = authorization) do
    with true <- exact_authorization?(authorization),
         true <- exact_plan?(authorization.plan),
         {:ok, expected} <- replan(authorization.plan),
         true <- expected === authorization.plan,
         :ok <- TriggerExecutionValidator.validate_started(authorization.execution),
         true <- correlated_execution?(authorization.execution, authorization.plan) do
      :ok
    else
      _failure -> {:error, :invalid_authorization}
    end
  rescue
    _error -> {:error, :invalid_authorization}
  catch
    _kind, _reason -> {:error, :invalid_authorization}
  end

  def validate(_authorization), do: {:error, :invalid_authorization}

  defp authorize_plan(plan, store) do
    with :ok <- validate_store(store) do
      start(store, plan)
    end
  end

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :start, 1),
      do: :ok,
      else: {:error, :invalid_authorization}
  end

  defp start(store, plan) do
    case store.start(plan) do
      {:ok, %TriggerExecution{} = execution} ->
        build_authorization(plan, execution)

      {:skip, reason} = skip
      when reason in [:already_terminal, :cooldown, :dedupe_window, :execution_in_progress] ->
        skip

      {:error, reason} when reason in [:event_conflict, :event_not_found, :invalid_execution] ->
        {:error, reason}

      {:error, :storage_unavailable} = error ->
        error

      _failure ->
        {:error, :storage_unavailable}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp build_authorization(plan, execution) do
    authorization = %Authorization{plan: plan, execution: execution}

    case validate(authorization) do
      :ok -> {:ok, authorization}
      {:error, :invalid_authorization} = error -> error
    end
  end

  defp replan(plan) do
    EventTriggerExecutionPlanner.plan(
      plan.trigger,
      plan.event,
      nil,
      plan.executed_at,
      plan.event_policy
    )
  end

  defp correlated_execution?(execution, plan) do
    execution.trigger_id === plan.trigger.id and execution.event_id === plan.event.id and
      same_datetime?(execution.executed_at, plan.executed_at) and
      same_datetime?(execution.cooldown_until, plan.cooldown_until)
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp exact_authorization?(authorization) do
    map_size(authorization) == @authorization_key_count and
      Enum.all?(@authorization_keys, &Map.has_key?(authorization, &1))
  end

  defp exact_plan?(%Plan{} = plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end

  defp exact_plan?(_plan), do: false
end

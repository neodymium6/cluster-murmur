defmodule ClusterMurmur.Runtime.RecurringScheduleInitializer do
  @moduledoc """
  Restores or initializes every configured recurring schedule before runtime.

  The complete bounded set of initial next runs is calculated before the first
  storage mutation. Existing durable state always wins, and returned state is
  correlated with the exact configured trigger before aggregate success is
  reported.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{
    ScheduleState,
    ScheduleStateRetirement,
    ScheduleStateStore
  }

  alias ClusterMurmur.Triggers.{ScheduleCalculator, ScheduleTrigger}

  @max_schedules 256
  @state_keys ScheduleState.__struct__() |> Map.keys()
  @state_key_count length(@state_keys)
  @retirement_keys ScheduleStateRetirement.__struct__() |> Map.keys()
  @retirement_key_count length(@retirement_keys)

  defmodule Adapters do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:states]
    defstruct [:states]

    @type t :: %__MODULE__{states: module()}
  end

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:schedule_count]}
    @enforce_keys [:schedule_count]
    defstruct [:schedule_count]

    @type t :: %__MODULE__{schedule_count: non_neg_integer()}
  end

  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)
  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)

  @doc "Restores or initializes the complete configured recurring-schedule set."
  @spec run(term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_recurring_schedule_initialization}
  def run(configuration, initialized_at) do
    run(configuration, initialized_at, %Adapters{states: ScheduleStateStore})
  end

  @doc false
  @spec run(term(), term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_recurring_schedule_initialization}
  def run(
        %Configuration{} = configuration,
        %DateTime{} = initialized_at,
        %Adapters{} = adapters
      ) do
    with :ok <- preflight(configuration, initialized_at, adapters),
         {:ok, versions} <- initial_versions(configuration, initialized_at),
         :ok <- retire_unconfigured(versions, adapters.states),
         :ok <- restore_versions(versions, adapters.states) do
      {:ok, %Result{schedule_count: length(versions)}}
    else
      _failure -> {:error, :invalid_recurring_schedule_initialization}
    end
  rescue
    _error -> {:error, :invalid_recurring_schedule_initialization}
  catch
    _kind, _reason -> {:error, :invalid_recurring_schedule_initialization}
  end

  def run(_configuration, _initialized_at, _adapters),
    do: {:error, :invalid_recurring_schedule_initialization}

  @doc "Validates one exact bounded aggregate initialization result."
  @spec validate_result(term()) ::
          :ok | {:error, :invalid_recurring_schedule_initialization_result}
  def validate_result(%Result{} = result) do
    if map_size(result) == @result_key_count and
         Enum.all?(@result_keys, &Map.has_key?(result, &1)) and
         is_integer(result.schedule_count) and result.schedule_count in 0..@max_schedules,
       do: :ok,
       else: {:error, :invalid_recurring_schedule_initialization_result}
  rescue
    _error -> {:error, :invalid_recurring_schedule_initialization_result}
  catch
    _kind, _reason -> {:error, :invalid_recurring_schedule_initialization_result}
  end

  def validate_result(_result),
    do: {:error, :invalid_recurring_schedule_initialization_result}

  defp preflight(configuration, initialized_at, adapters) do
    with :ok <- normalize_configuration(Configuration.validate(configuration)),
         :ok <- DateTimeValidator.validate_storage_utc(initialized_at),
         true <- exact_adapters?(adapters),
         :ok <-
           validate_adapter(adapters.states,
             retire_unconfigured: 1,
             restore_or_initialize: 2
           ) do
      :ok
    else
      _failure -> {:error, :invalid_recurring_schedule_initialization}
    end
  end

  defp initial_versions(configuration, initialized_at) do
    triggers =
      configuration.triggers.triggers
      |> Map.values()
      |> Enum.filter(&match?(%ScheduleTrigger{}, &1))
      |> Enum.sort_by(& &1.id)

    if bounded?(triggers) do
      calculate_versions(triggers, initialized_at, [])
    else
      {:error, :invalid_recurring_schedule_initialization}
    end
  end

  defp calculate_versions([], _initialized_at, versions),
    do: {:ok, Enum.reverse(versions)}

  defp calculate_versions([trigger | rest], initialized_at, versions) do
    case ScheduleCalculator.next_run(trigger, initialized_at) do
      {:ok, %DateTime{} = next_run_at} ->
        if DateTimeValidator.validate_storage_utc(next_run_at) == :ok,
          do: calculate_versions(rest, initialized_at, [{trigger.id, next_run_at} | versions]),
          else: {:error, :invalid_recurring_schedule_initialization}

      _failure ->
        {:error, :invalid_recurring_schedule_initialization}
    end
  end

  defp calculate_versions(_triggers, _initialized_at, _versions),
    do: {:error, :invalid_recurring_schedule_initialization}

  defp restore_versions(versions, states) do
    Enum.reduce_while(versions, :ok, fn {trigger_id, next_run_at}, :ok ->
      case states.restore_or_initialize(trigger_id, next_run_at) do
        {:ok, %ScheduleState{} = state} ->
          if valid_restored_state?(state, trigger_id),
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_recurring_schedule_initialization}}

        _failure ->
          {:halt, {:error, :invalid_recurring_schedule_initialization}}
      end
    end)
  end

  defp retire_unconfigured(versions, states) do
    active_trigger_ids = Enum.map(versions, &elem(&1, 0))

    case states.retire_unconfigured(active_trigger_ids) do
      {:ok, %ScheduleStateRetirement{saturated?: false} = result} ->
        if exact_retirement?(result),
          do: :ok,
          else: {:error, :invalid_recurring_schedule_initialization}

      _failure ->
        {:error, :invalid_recurring_schedule_initialization}
    end
  end

  defp valid_restored_state?(state, trigger_id) do
    exact_state?(state) and state.trigger_id == trigger_id and
      ScheduleState.changeset(state, %{}).valid? and state.claim_token == nil and
      state.claim_started_at == nil and state.claim_expires_at == nil
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp bounded?(triggers) do
    Enum.reduce_while(triggers, 0, fn _trigger, count ->
      if count < @max_schedules, do: {:cont, count + 1}, else: {:halt, :oversized}
    end) != :oversized
  end

  defp validate_adapter(adapter, callbacks) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end),
       do: :ok,
       else: {:error, :invalid_recurring_schedule_initialization}
  end

  defp normalize_configuration(:ok), do: :ok

  defp normalize_configuration(_failure),
    do: {:error, :invalid_recurring_schedule_initialization}

  defp exact_adapters?(adapters) do
    map_size(adapters) == @adapter_key_count and
      Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
  end

  defp exact_state?(state) do
    map_size(state) == @state_key_count and Enum.all?(@state_keys, &Map.has_key?(state, &1))
  end

  defp exact_retirement?(result) do
    map_size(result) == @retirement_key_count and
      Enum.all?(@retirement_keys, &Map.has_key?(result, &1)) and
      is_integer(result.retired_count) and result.retired_count in 0..100 and
      is_boolean(result.saturated?)
  end
end

defmodule ClusterMurmur.Runtime.StochasticScheduleInitializer do
  @moduledoc """
  Restores or initializes every configured stochastic schedule before runtime.

  The complete bounded set of sampled initial runs is calculated before the
  first storage mutation. Existing durable state always wins, and returned
  state is correlated with the exact configured trigger before success.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{
    StochasticSchedule,
    StochasticScheduleRetirement,
    StochasticScheduleStore
  }

  alias ClusterMurmur.Triggers.{StochasticScheduleCalculator, StochasticTrigger}

  @max_schedules 256
  @schedule_keys StochasticSchedule.__struct__() |> Map.keys()
  @schedule_key_count length(@schedule_keys)
  @retirement_keys StochasticScheduleRetirement.__struct__() |> Map.keys()
  @retirement_key_count length(@retirement_keys)

  defmodule Adapters do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:schedules]
    defstruct [:schedules]

    @type t :: %__MODULE__{schedules: module()}
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

  @doc "Restores or initializes the complete configured stochastic-schedule set."
  @spec run(term(), term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_stochastic_schedule_initialization}
  def run(configuration, initialized_at, random) do
    run(configuration, initialized_at, random, %Adapters{schedules: StochasticScheduleStore})
  end

  @doc false
  @spec run(term(), term(), term(), term()) ::
          {:ok, Result.t()} | {:error, :invalid_stochastic_schedule_initialization}
  def run(
        %Configuration{} = configuration,
        %DateTime{} = initialized_at,
        random,
        %Adapters{} = adapters
      ) do
    with :ok <- preflight(configuration, initialized_at, random, adapters),
         {:ok, versions} <- initial_versions(configuration, initialized_at, random),
         :ok <- retire_unconfigured(versions, adapters.schedules),
         :ok <- restore_versions(versions, adapters.schedules) do
      {:ok, %Result{schedule_count: length(versions)}}
    else
      _failure -> {:error, :invalid_stochastic_schedule_initialization}
    end
  rescue
    _error -> {:error, :invalid_stochastic_schedule_initialization}
  catch
    _kind, _reason -> {:error, :invalid_stochastic_schedule_initialization}
  end

  def run(_configuration, _initialized_at, _random, _adapters),
    do: {:error, :invalid_stochastic_schedule_initialization}

  @doc "Validates one exact bounded aggregate initialization result."
  @spec validate_result(term()) ::
          :ok | {:error, :invalid_stochastic_schedule_initialization_result}
  def validate_result(%Result{} = result) do
    if map_size(result) == @result_key_count and
         Enum.all?(@result_keys, &Map.has_key?(result, &1)) and
         is_integer(result.schedule_count) and result.schedule_count in 0..@max_schedules,
       do: :ok,
       else: {:error, :invalid_stochastic_schedule_initialization_result}
  rescue
    _error -> {:error, :invalid_stochastic_schedule_initialization_result}
  catch
    _kind, _reason -> {:error, :invalid_stochastic_schedule_initialization_result}
  end

  def validate_result(_result),
    do: {:error, :invalid_stochastic_schedule_initialization_result}

  defp preflight(configuration, initialized_at, random, adapters) do
    with :ok <- normalize_configuration(Configuration.validate(configuration)),
         :ok <- DateTimeValidator.validate_storage_utc(initialized_at),
         :ok <- validate_adapter(random, uniform: 0),
         true <- exact_adapters?(adapters),
         :ok <-
           validate_adapter(adapters.schedules,
             retire_unconfigured: 1,
             restore_or_initialize: 2
           ) do
      :ok
    else
      _failure -> {:error, :invalid_stochastic_schedule_initialization}
    end
  end

  defp initial_versions(configuration, initialized_at, random) do
    triggers =
      configuration.triggers.triggers
      |> Map.values()
      |> Enum.filter(&match?(%StochasticTrigger{}, &1))
      |> Enum.sort_by(& &1.id)

    if bounded?(triggers),
      do: calculate_versions(triggers, initialized_at, random, []),
      else: {:error, :invalid_stochastic_schedule_initialization}
  end

  defp calculate_versions([], _initialized_at, _random, versions),
    do: {:ok, Enum.reverse(versions)}

  defp calculate_versions([trigger | rest], initialized_at, random, versions) do
    case StochasticScheduleCalculator.next_run(trigger, initialized_at, random) do
      {:ok, %DateTime{} = next_run_at} ->
        if DateTimeValidator.validate_storage_utc(next_run_at) == :ok,
          do:
            calculate_versions(
              rest,
              initialized_at,
              random,
              [{trigger.id, next_run_at} | versions]
            ),
          else: {:error, :invalid_stochastic_schedule_initialization}

      _failure ->
        {:error, :invalid_stochastic_schedule_initialization}
    end
  end

  defp restore_versions(versions, schedules) do
    Enum.reduce_while(versions, :ok, fn {trigger_id, next_run_at}, :ok ->
      case schedules.restore_or_initialize(trigger_id, next_run_at) do
        {:ok, %StochasticSchedule{} = schedule} ->
          if valid_restored_schedule?(schedule, trigger_id),
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_stochastic_schedule_initialization}}

        _failure ->
          {:halt, {:error, :invalid_stochastic_schedule_initialization}}
      end
    end)
  end

  defp retire_unconfigured(versions, schedules) do
    active_trigger_ids = Enum.map(versions, &elem(&1, 0))

    case schedules.retire_unconfigured(active_trigger_ids) do
      {:ok, %StochasticScheduleRetirement{saturated?: false} = result} ->
        if exact_retirement?(result),
          do: :ok,
          else: {:error, :invalid_stochastic_schedule_initialization}

      _failure ->
        {:error, :invalid_stochastic_schedule_initialization}
    end
  end

  defp valid_restored_schedule?(schedule, trigger_id) do
    exact_schedule?(schedule) and schedule.trigger_id == trigger_id and
      valid_schedule_values?(schedule) and schedule.claim_token == nil and
      schedule.claim_started_at == nil and schedule.claim_expires_at == nil
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_schedule_values?(schedule) do
    StochasticSchedule.changeset(%StochasticSchedule{}, %{
      trigger_id: schedule.trigger_id,
      next_run_at: schedule.next_run_at,
      last_run_at: schedule.last_run_at,
      daily_count: schedule.daily_count,
      daily_count_date: schedule.daily_count_date,
      claim_token: schedule.claim_token,
      claim_started_at: schedule.claim_started_at,
      claim_expires_at: schedule.claim_expires_at
    }).valid?
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
       else: {:error, :invalid_stochastic_schedule_initialization}
  end

  defp normalize_configuration(:ok), do: :ok

  defp normalize_configuration(_failure),
    do: {:error, :invalid_stochastic_schedule_initialization}

  defp exact_adapters?(adapters) do
    map_size(adapters) == @adapter_key_count and
      Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
  end

  defp exact_schedule?(schedule) do
    map_size(schedule) == @schedule_key_count and
      Enum.all?(@schedule_keys, &Map.has_key?(schedule, &1))
  end

  defp exact_retirement?(result) do
    map_size(result) == @retirement_key_count and
      Enum.all?(@retirement_keys, &Map.has_key?(result, &1)) and
      is_integer(result.retired_count) and result.retired_count in 0..100 and
      is_boolean(result.saturated?)
  end
end

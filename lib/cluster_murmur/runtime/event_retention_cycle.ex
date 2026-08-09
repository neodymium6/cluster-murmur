defmodule ClusterMurmur.Runtime.EventRetentionCycle do
  @moduledoc """
  Runs one bounded event-retention cleanup operation.

  The caller supplies the complete normalized configuration and one injected
  UTC instant. The cycle derives an exact retention plan and delegates one
  fixed marker-pruning batch to its narrow store adapter. It does not read a
  clock, repeat cleanup, schedule work, or delete immutable event records.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.RetentionPlanner
  alias ClusterMurmur.Persistence.EventDedupeMarkerStore

  @max_pruned 100

  defmodule Adapters do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:dedupe_markers]
    defstruct [:dedupe_markers]

    @type t :: %__MODULE__{dedupe_markers: module()}
  end

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:pruned_marker_count]}
    @enforce_keys [:pruned_marker_count]
    defstruct [:pruned_marker_count]

    @type t :: %__MODULE__{pruned_marker_count: 0..100}
  end

  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)
  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)

  @type error :: :event_retention_failed | :invalid_event_retention_cycle

  @doc "Runs one marker-retention batch through the fixed durable store."
  @spec run(term(), term()) :: {:ok, Result.t()} | {:error, error()}
  def run(configuration, now) do
    run(configuration, now, %Adapters{dedupe_markers: EventDedupeMarkerStore})
  end

  @doc false
  @spec run(term(), term(), term()) :: {:ok, Result.t()} | {:error, error()}
  def run(%Configuration{} = configuration, %DateTime{} = now, %Adapters{} = adapters) do
    with :ok <- preflight(configuration, now, adapters),
         {:ok, plan} <- normalize_plan(RetentionPlanner.plan(configuration.event_policy, now)),
         {:ok, count} <- prune(plan, adapters.dedupe_markers) do
      {:ok, %Result{pruned_marker_count: count}}
    else
      {:error, reason}
      when reason in [:event_retention_failed, :invalid_event_retention_cycle] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_event_retention_cycle}
    end
  rescue
    _error -> {:error, :invalid_event_retention_cycle}
  catch
    _kind, _reason -> {:error, :invalid_event_retention_cycle}
  end

  def run(_configuration, _now, _adapters),
    do: {:error, :invalid_event_retention_cycle}

  @doc "Validates one exact bounded aggregate cleanup result."
  @spec validate_result(term()) :: :ok | {:error, :invalid_event_retention_cycle_result}
  def validate_result(%Result{} = result) do
    if exact_result?(result) and is_integer(result.pruned_marker_count) and
         result.pruned_marker_count in 0..@max_pruned,
       do: :ok,
       else: {:error, :invalid_event_retention_cycle_result}
  rescue
    _error -> {:error, :invalid_event_retention_cycle_result}
  catch
    _kind, _reason -> {:error, :invalid_event_retention_cycle_result}
  end

  def validate_result(_result), do: {:error, :invalid_event_retention_cycle_result}

  defp preflight(configuration, now, adapters) do
    with :ok <- normalize_configuration(Configuration.validate(configuration)),
         :ok <- normalize_datetime(DateTimeValidator.validate_storage_utc(now)),
         true <- exact_adapters?(adapters),
         true <- valid_module?(adapters.dedupe_markers, prune: 1) do
      :ok
    else
      _failure -> {:error, :invalid_event_retention_cycle}
    end
  end

  defp prune(plan, store) do
    case store.prune(plan) do
      {:ok, count} when is_integer(count) and count in 0..@max_pruned -> {:ok, count}
      {:error, :storage_unavailable} -> {:error, :event_retention_failed}
      {:error, :invalid_retention_plan} -> {:error, :invalid_event_retention_cycle}
      _failure -> {:error, :invalid_event_retention_cycle}
    end
  end

  defp normalize_configuration(:ok), do: :ok
  defp normalize_configuration(_failure), do: {:error, :invalid_event_retention_cycle}

  defp normalize_datetime(:ok), do: :ok
  defp normalize_datetime(_failure), do: {:error, :invalid_event_retention_cycle}

  defp normalize_plan({:ok, plan}), do: {:ok, plan}
  defp normalize_plan(_failure), do: {:error, :invalid_event_retention_cycle}

  defp valid_module?(module, functions) do
    is_atom(module) and Code.ensure_loaded?(module) and
      Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp exact_adapters?(adapters) do
    map_size(adapters) == @adapter_key_count and
      Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
  end

  defp exact_result?(result) do
    map_size(result) == @result_key_count and Enum.all?(@result_keys, &Map.has_key?(result, &1))
  end
end

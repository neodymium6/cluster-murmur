defmodule ClusterMurmur.Runtime.SchedulerSettings do
  @moduledoc """
  Loads bounded non-secret cadence settings for the five runtime schedulers.

  Values use the public configuration duration syntax and fixed environment
  variable names. Loading performs no clock read, persistence access, external
  call, or worker start.
  """

  alias ClusterMurmur.Config.Duration
  alias ClusterMurmur.DomainLimits

  @poll_environment "CLUSTER_MURMUR_POLL_INTERVAL"
  @event_dispatch_environment "CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL"
  @recurring_environment "CLUSTER_MURMUR_RECURRING_INTERVAL"
  @stochastic_environment "CLUSTER_MURMUR_STOCHASTIC_INTERVAL"
  @event_retention_environment "CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL"

  @minimum_cycle_interval_ms 1_000
  @minimum_retention_interval_ms 60_000
  @maximum_interval_ms DomainLimits.max_interval_ms()
  @maximum_encoded_duration_bytes 32

  @derive {Inspect,
           only: [
             :poll_interval_ms,
             :event_dispatch_interval_ms,
             :recurring_interval_ms,
             :stochastic_interval_ms,
             :event_retention_interval_ms
           ]}
  @enforce_keys [
    :poll_interval_ms,
    :event_dispatch_interval_ms,
    :recurring_interval_ms,
    :stochastic_interval_ms,
    :event_retention_interval_ms
  ]
  defstruct [
    :poll_interval_ms,
    :event_dispatch_interval_ms,
    :recurring_interval_ms,
    :stochastic_interval_ms,
    :event_retention_interval_ms
  ]

  @settings_keys [
    :__struct__,
    :event_dispatch_interval_ms,
    :event_retention_interval_ms,
    :poll_interval_ms,
    :recurring_interval_ms,
    :stochastic_interval_ms
  ]
  @settings_key_count length(@settings_keys)

  @type t :: %__MODULE__{
          poll_interval_ms: pos_integer(),
          event_dispatch_interval_ms: pos_integer(),
          recurring_interval_ms: pos_integer(),
          stochastic_interval_ms: pos_integer(),
          event_retention_interval_ms: pos_integer()
        }

  @type error ::
          :invalid_scheduler_settings
          | :missing_poll_interval
          | :invalid_poll_interval
          | :missing_event_dispatch_interval
          | :invalid_event_dispatch_interval
          | :missing_recurring_interval
          | :invalid_recurring_interval
          | :missing_stochastic_interval
          | :invalid_stochastic_interval
          | :missing_event_retention_interval
          | :invalid_event_retention_interval

  @type environment_reader :: (String.t() -> {:ok, String.t()} | :error)

  @doc "Loads every required scheduler interval without starting a scheduler."
  @spec load(environment_reader()) :: {:ok, t()} | {:error, error()}
  def load(environment_reader \\ &System.fetch_env/1)

  def load(environment_reader) when is_function(environment_reader, 1) do
    with {:ok, poll_interval_ms} <-
           read_interval(
             environment_reader,
             @poll_environment,
             @minimum_cycle_interval_ms,
             :missing_poll_interval,
             :invalid_poll_interval
           ),
         {:ok, event_dispatch_interval_ms} <-
           read_interval(
             environment_reader,
             @event_dispatch_environment,
             @minimum_cycle_interval_ms,
             :missing_event_dispatch_interval,
             :invalid_event_dispatch_interval
           ),
         {:ok, recurring_interval_ms} <-
           read_interval(
             environment_reader,
             @recurring_environment,
             @minimum_cycle_interval_ms,
             :missing_recurring_interval,
             :invalid_recurring_interval
           ),
         {:ok, stochastic_interval_ms} <-
           read_interval(
             environment_reader,
             @stochastic_environment,
             @minimum_cycle_interval_ms,
             :missing_stochastic_interval,
             :invalid_stochastic_interval
           ),
         {:ok, event_retention_interval_ms} <-
           read_interval(
             environment_reader,
             @event_retention_environment,
             @minimum_retention_interval_ms,
             :missing_event_retention_interval,
             :invalid_event_retention_interval
           ) do
      {:ok,
       %__MODULE__{
         poll_interval_ms: poll_interval_ms,
         event_dispatch_interval_ms: event_dispatch_interval_ms,
         recurring_interval_ms: recurring_interval_ms,
         stochastic_interval_ms: stochastic_interval_ms,
         event_retention_interval_ms: event_retention_interval_ms
       }}
    end
  rescue
    _error -> {:error, :invalid_scheduler_settings}
  catch
    _kind, _reason -> {:error, :invalid_scheduler_settings}
  end

  def load(_environment_reader), do: {:error, :invalid_scheduler_settings}

  @doc "Revalidates the exact bounded cadence value before option construction."
  @spec validate(term()) :: :ok | {:error, :invalid_scheduler_settings}
  def validate(%__MODULE__{} = settings) do
    if exact_settings?(settings) and
         valid_interval?(settings.poll_interval_ms, @minimum_cycle_interval_ms) and
         valid_interval?(settings.event_dispatch_interval_ms, @minimum_cycle_interval_ms) and
         valid_interval?(settings.recurring_interval_ms, @minimum_cycle_interval_ms) and
         valid_interval?(settings.stochastic_interval_ms, @minimum_cycle_interval_ms) and
         valid_interval?(settings.event_retention_interval_ms, @minimum_retention_interval_ms) do
      :ok
    else
      {:error, :invalid_scheduler_settings}
    end
  rescue
    _error -> {:error, :invalid_scheduler_settings}
  catch
    _kind, _reason -> {:error, :invalid_scheduler_settings}
  end

  def validate(_settings), do: {:error, :invalid_scheduler_settings}

  defp read_interval(environment_reader, name, minimum, missing_error, invalid_error) do
    case environment_reader.(name) do
      {:ok, value}
      when is_binary(value) and byte_size(value) in 1..@maximum_encoded_duration_bytes ->
        case Duration.parse(value) do
          {:ok, interval_ms} ->
            if valid_interval?(interval_ms, minimum),
              do: {:ok, interval_ms},
              else: {:error, invalid_error}

          {:error, :invalid_duration} ->
            {:error, invalid_error}
        end

      :error ->
        {:error, missing_error}

      _invalid ->
        {:error, invalid_error}
    end
  end

  defp valid_interval?(value, minimum),
    do: is_integer(value) and value in minimum..@maximum_interval_ms

  defp exact_settings?(settings) do
    map_size(settings) == @settings_key_count and
      Enum.all?(@settings_keys, &Map.has_key?(settings, &1))
  end
end

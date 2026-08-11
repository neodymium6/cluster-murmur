defmodule ClusterMurmur.Runtime.ResponderScheduleSettings do
  @moduledoc """
  Loads bounded non-secret timing inputs for reusable responder schedules.

  Every value is deployment-owned and uses the public duration syntax. The
  settings describe relative planned timestamps only; loading does not sleep,
  read a clock, access persistence, call an external service, or build a
  schedule.
  """

  alias ClusterMurmur.Config.Duration
  alias ClusterMurmur.DomainLimits

  @turn_interval_environment "CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL"
  @generation_delay_environment "CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY"
  @publication_start_delay_environment "CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY"
  @publication_complete_delay_environment "CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY"

  @minimum_turn_interval_ms 1_000
  @maximum_interval_ms DomainLimits.max_interval_ms()
  @maximum_encoded_duration_bytes 32

  @derive {Inspect,
           only: [
             :turn_interval_ms,
             :generation_delay_ms,
             :publication_start_delay_ms,
             :publication_complete_delay_ms
           ]}
  @enforce_keys [
    :turn_interval_ms,
    :generation_delay_ms,
    :publication_start_delay_ms,
    :publication_complete_delay_ms
  ]
  defstruct [
    :turn_interval_ms,
    :generation_delay_ms,
    :publication_start_delay_ms,
    :publication_complete_delay_ms
  ]

  @settings_keys [
    :__struct__,
    :generation_delay_ms,
    :publication_complete_delay_ms,
    :publication_start_delay_ms,
    :turn_interval_ms
  ]
  @settings_key_count length(@settings_keys)

  @type t :: %__MODULE__{
          turn_interval_ms: pos_integer(),
          generation_delay_ms: non_neg_integer(),
          publication_start_delay_ms: non_neg_integer(),
          publication_complete_delay_ms: non_neg_integer()
        }

  @type error ::
          :invalid_responder_schedule_settings
          | :missing_responder_turn_interval
          | :invalid_responder_turn_interval
          | :missing_responder_generation_delay
          | :invalid_responder_generation_delay
          | :missing_responder_publication_start_delay
          | :invalid_responder_publication_start_delay
          | :missing_responder_publication_complete_delay
          | :invalid_responder_publication_complete_delay

  @type environment_reader :: (String.t() -> {:ok, String.t()} | :error)

  @doc "Loads every required responder timing without constructing a schedule."
  @spec load(environment_reader()) :: {:ok, t()} | {:error, error()}
  def load(environment_reader \\ &System.fetch_env/1)

  def load(environment_reader) when is_function(environment_reader, 1) do
    with {:ok, turn_interval_ms} <-
           read_duration(
             environment_reader,
             @turn_interval_environment,
             @minimum_turn_interval_ms,
             :missing_responder_turn_interval,
             :invalid_responder_turn_interval
           ),
         {:ok, generation_delay_ms} <-
           read_duration(
             environment_reader,
             @generation_delay_environment,
             0,
             :missing_responder_generation_delay,
             :invalid_responder_generation_delay
           ),
         {:ok, publication_start_delay_ms} <-
           read_duration(
             environment_reader,
             @publication_start_delay_environment,
             0,
             :missing_responder_publication_start_delay,
             :invalid_responder_publication_start_delay
           ),
         {:ok, publication_complete_delay_ms} <-
           read_duration(
             environment_reader,
             @publication_complete_delay_environment,
             0,
             :missing_responder_publication_complete_delay,
             :invalid_responder_publication_complete_delay
           ),
         settings = %__MODULE__{
           turn_interval_ms: turn_interval_ms,
           generation_delay_ms: generation_delay_ms,
           publication_start_delay_ms: publication_start_delay_ms,
           publication_complete_delay_ms: publication_complete_delay_ms
         },
         :ok <- validate(settings) do
      {:ok, settings}
    else
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :invalid_responder_schedule_settings}
  catch
    _kind, _reason -> {:error, :invalid_responder_schedule_settings}
  end

  def load(_environment_reader), do: {:error, :invalid_responder_schedule_settings}

  @doc "Revalidates one exact ordered responder timing value."
  @spec validate(term()) :: :ok | {:error, :invalid_responder_schedule_settings}
  def validate(%__MODULE__{} = settings) do
    if exact_settings?(settings) and
         valid_duration?(settings.turn_interval_ms, @minimum_turn_interval_ms) and
         valid_duration?(settings.generation_delay_ms, 0) and
         valid_duration?(settings.publication_start_delay_ms, 0) and
         valid_duration?(settings.publication_complete_delay_ms, 0) and
         settings.generation_delay_ms <= settings.publication_start_delay_ms and
         settings.publication_start_delay_ms <= settings.publication_complete_delay_ms and
         settings.publication_complete_delay_ms <= settings.turn_interval_ms do
      :ok
    else
      {:error, :invalid_responder_schedule_settings}
    end
  rescue
    _error -> {:error, :invalid_responder_schedule_settings}
  catch
    _kind, _reason -> {:error, :invalid_responder_schedule_settings}
  end

  def validate(_settings), do: {:error, :invalid_responder_schedule_settings}

  defp read_duration(environment_reader, name, minimum, missing_error, invalid_error) do
    case environment_reader.(name) do
      {:ok, value}
      when is_binary(value) and byte_size(value) in 1..@maximum_encoded_duration_bytes ->
        case Duration.parse(value) do
          {:ok, duration_ms} ->
            if valid_duration?(duration_ms, minimum),
              do: {:ok, duration_ms},
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

  defp valid_duration?(value, minimum),
    do: is_integer(value) and value in minimum..@maximum_interval_ms

  defp exact_settings?(settings) do
    map_size(settings) == @settings_key_count and
      Enum.all?(@settings_keys, &Map.has_key?(settings, &1))
  end
end

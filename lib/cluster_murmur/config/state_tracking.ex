defmodule ClusterMurmur.Config.StateTracking do
  @moduledoc """
  Validates version 1 observation debounce settings.

  Public failure and success counts are normalized without reading an observer
  or durable state. The resulting value can project only the fixed
  `DebouncePolicy` consumed by application-owned ingestion decisions.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Observations.DebouncePolicy

  @document_keys ["failures_required", "successes_required"]
  @document_key_count length(@document_keys)
  @struct_keys [:__struct__, :failures_required, :successes_required]
  @struct_key_count length(@struct_keys)
  @max_threshold DomainLimits.max_safe_integer()
  @default_threshold 2

  @derive {Inspect, only: [:failures_required, :successes_required]}
  @enforce_keys [:failures_required, :successes_required]
  defstruct [:failures_required, :successes_required]

  @type t :: %__MODULE__{
          failures_required: pos_integer(),
          successes_required: pos_integer()
        }

  @type error :: :invalid_state_tracking_configuration

  @doc "Returns the fixed version 1 default debounce settings."
  @spec default() :: t()
  def default do
    %__MODULE__{
      failures_required: @default_threshold,
      successes_required: @default_threshold
    }
  end

  @doc "Parses one exact decoded version 1 state-tracking mapping."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) and not is_struct(document) do
    with true <- exact_document?(document),
         true <- valid_threshold?(document["failures_required"]),
         true <- valid_threshold?(document["successes_required"]) do
      {:ok,
       %__MODULE__{
         failures_required: document["failures_required"],
         successes_required: document["successes_required"]
       }}
    else
      _failure -> {:error, :invalid_state_tracking_configuration}
    end
  rescue
    _error -> {:error, :invalid_state_tracking_configuration}
  catch
    _kind, _reason -> {:error, :invalid_state_tracking_configuration}
  end

  def parse(_document), do: {:error, :invalid_state_tracking_configuration}

  @doc "Revalidates one exact normalized state-tracking value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = state_tracking) do
    if exact_struct?(state_tracking) and valid_threshold?(state_tracking.failures_required) and
         valid_threshold?(state_tracking.successes_required),
       do: :ok,
       else: {:error, :invalid_state_tracking_configuration}
  rescue
    _error -> {:error, :invalid_state_tracking_configuration}
  catch
    _kind, _reason -> {:error, :invalid_state_tracking_configuration}
  end

  def validate(_state_tracking), do: {:error, :invalid_state_tracking_configuration}

  @doc "Projects the only debounce policy accepted by observation ingestion."
  @spec to_debounce_policy(term()) :: {:ok, DebouncePolicy.t()} | {:error, error()}
  def to_debounce_policy(state_tracking) do
    case validate(state_tracking) do
      :ok ->
        {:ok,
         %DebouncePolicy{
           healthy_threshold: state_tracking.successes_required,
           unhealthy_threshold: state_tracking.failures_required
         }}

      {:error, :invalid_state_tracking_configuration} = error ->
        error
    end
  end

  @doc false
  @spec to_document(term()) :: {:ok, map()} | {:error, error()}
  def to_document(state_tracking) do
    case validate(state_tracking) do
      :ok ->
        {:ok,
         %{
           "failures_required" => state_tracking.failures_required,
           "successes_required" => state_tracking.successes_required
         }}

      {:error, :invalid_state_tracking_configuration} = error ->
        error
    end
  end

  defp exact_document?(document) do
    map_size(document) == @document_key_count and
      Enum.all?(@document_keys, &Map.has_key?(document, &1))
  end

  defp exact_struct?(state_tracking) do
    map_size(state_tracking) == @struct_key_count and
      Enum.all?(@struct_keys, &Map.has_key?(state_tracking, &1))
  end

  defp valid_threshold?(value),
    do: is_integer(value) and value in 1..@max_threshold
end

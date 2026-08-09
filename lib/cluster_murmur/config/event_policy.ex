defmodule ClusterMurmur.Config.EventPolicy do
  @moduledoc """
  Validates immutable version 1 event lifecycle policy.

  The normalized value contains only bounded application-owned durations used
  by durable deduplication and later retention cleanup. It contains no event
  facts, storage handles, clocks, or deployment capabilities.
  """

  alias ClusterMurmur.Config.Duration
  alias ClusterMurmur.DomainLimits

  @document_keys ["dedupe_window", "retention"]
  @struct_keys [:__struct__, :dedupe_window_ms, :retention_ms]
  @max_duration_ms DomainLimits.max_interval_ms()

  @derive {Inspect, only: [:dedupe_window_ms, :retention_ms]}
  @enforce_keys [:dedupe_window_ms, :retention_ms]
  defstruct [:dedupe_window_ms, :retention_ms]

  @type t :: %__MODULE__{
          dedupe_window_ms: pos_integer(),
          retention_ms: pos_integer()
        }

  @type error :: :invalid_event_policy

  @doc "Returns the fixed version 1 event policy."
  @spec default() :: t()
  def default do
    %__MODULE__{
      dedupe_window_ms: 300_000,
      retention_ms: 90 * 86_400_000
    }
  end

  @doc "Parses one exact decoded version 1 event-policy mapping."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) and not is_struct(document) do
    with true <- exact_map?(document, @document_keys),
         {:ok, dedupe_window_ms} <- Duration.parse(document["dedupe_window"]),
         {:ok, retention_ms} <- Duration.parse(document["retention"]),
         candidate = %__MODULE__{
           dedupe_window_ms: dedupe_window_ms,
           retention_ms: retention_ms
         },
         :ok <- validate(candidate) do
      {:ok, candidate}
    else
      _failure -> {:error, :invalid_event_policy}
    end
  rescue
    _error -> {:error, :invalid_event_policy}
  catch
    _kind, _reason -> {:error, :invalid_event_policy}
  end

  def parse(_document), do: {:error, :invalid_event_policy}

  @doc "Revalidates one exact normalized event-policy value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = policy) do
    if exact_map?(policy, @struct_keys) and valid_duration?(policy.dedupe_window_ms) and
         valid_duration?(policy.retention_ms) and policy.retention_ms >= policy.dedupe_window_ms,
       do: :ok,
       else: {:error, :invalid_event_policy}
  rescue
    _error -> {:error, :invalid_event_policy}
  catch
    _kind, _reason -> {:error, :invalid_event_policy}
  end

  def validate(_policy), do: {:error, :invalid_event_policy}

  @doc false
  @spec to_document(term()) :: {:ok, map()} | {:error, error()}
  def to_document(policy) do
    case validate(policy) do
      :ok ->
        {:ok,
         %{
           "dedupe_window" => "#{policy.dedupe_window_ms}ms",
           "retention" => "#{policy.retention_ms}ms"
         }}

      {:error, :invalid_event_policy} = error ->
        error
    end
  end

  defp valid_duration?(value), do: is_integer(value) and value in 1..@max_duration_ms

  defp exact_map?(value, keys),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
end

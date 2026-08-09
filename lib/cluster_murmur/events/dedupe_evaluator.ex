defmodule ClusterMurmur.Events.DedupeEvaluator do
  @moduledoc """
  Purely evaluates one event against a bounded deduplication marker.

  The caller supplies the last durably accepted marker and one injected UTC
  instant. This module neither reads a clock nor persists, dispatches, or
  exposes event identifiers through inspection.
  """

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, Validator}

  defmodule Marker do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:dedupe_key, :event_id, :accepted_at]
    defstruct [:dedupe_key, :event_id, :accepted_at]

    @type t :: %__MODULE__{
            dedupe_key: String.t(),
            event_id: String.t(),
            accepted_at: DateTime.t()
          }
  end

  @marker_keys Marker.__struct__() |> Map.keys()
  @marker_key_count length(@marker_keys)

  @type decision :: {:accept, Marker.t() | nil} | {:skip, :dedupe_window}
  @type error :: :invalid_datetime | :invalid_event | :invalid_event_policy | :invalid_marker

  @doc "Returns the next marker or a stable suppression reason without effects."
  @spec evaluate(term(), term(), term(), term()) ::
          {:ok, decision()} | {:error, error()}
  def evaluate(event, marker, policy, evaluated_at) do
    with :ok <- Validator.validate(event),
         :ok <- EventPolicy.validate(policy),
         :ok <- DateTimeValidator.validate_storage_utc(evaluated_at),
         :ok <- validate_marker(marker, event, evaluated_at) do
      decide(event, marker, policy, evaluated_at)
    else
      {:error, reason}
      when reason in [:invalid_datetime, :invalid_event, :invalid_event_policy, :invalid_marker] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_marker}
    end
  rescue
    _error -> {:error, :invalid_marker}
  catch
    _kind, _reason -> {:error, :invalid_marker}
  end

  defp validate_marker(nil, %Event{dedupe_key: nil}, _evaluated_at), do: :ok

  defp validate_marker(nil, %Event{dedupe_key: dedupe_key}, _evaluated_at)
       when is_binary(dedupe_key),
       do: :ok

  defp validate_marker(
         %Marker{} = marker,
         %Event{dedupe_key: dedupe_key},
         evaluated_at
       )
       when is_binary(dedupe_key) do
    with true <- exact_marker?(marker),
         :ok <- Validator.validate_id(marker.dedupe_key),
         :ok <- Validator.validate_id(marker.event_id),
         :ok <- DateTimeValidator.validate_storage_utc(marker.accepted_at),
         true <- marker.dedupe_key === dedupe_key,
         true <- DateTime.compare(marker.accepted_at, evaluated_at) in [:lt, :eq] do
      :ok
    else
      _failure -> {:error, :invalid_marker}
    end
  end

  defp validate_marker(_marker, _event, _evaluated_at), do: {:error, :invalid_marker}

  defp decide(%Event{dedupe_key: nil}, nil, _policy, _evaluated_at),
    do: {:ok, {:accept, nil}}

  defp decide(event, nil, _policy, evaluated_at),
    do: {:ok, {:accept, marker(event, evaluated_at)}}

  defp decide(%Event{id: event_id}, %Marker{event_id: event_id} = marker, _policy, _evaluated_at),
    do: {:ok, {:accept, marker}}

  defp decide(event, marker, policy, evaluated_at) do
    elapsed_microseconds = DateTime.diff(evaluated_at, marker.accepted_at, :microsecond)
    window_microseconds = policy.dedupe_window_ms * 1_000

    if elapsed_microseconds < window_microseconds,
      do: {:ok, {:skip, :dedupe_window}},
      else: {:ok, {:accept, marker(event, evaluated_at)}}
  end

  defp marker(event, evaluated_at) do
    %Marker{
      dedupe_key: event.dedupe_key,
      event_id: event.id,
      accepted_at: evaluated_at
    }
  end

  defp exact_marker?(marker) do
    map_size(marker) == @marker_key_count and Enum.all?(@marker_keys, &Map.has_key?(marker, &1))
  end
end

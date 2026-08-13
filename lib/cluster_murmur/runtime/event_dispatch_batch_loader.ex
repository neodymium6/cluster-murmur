defmodule ClusterMurmur.Runtime.EventDispatchBatchLoader do
  @moduledoc false

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Persistence.EventDispatchCandidate

  @max_candidates 100
  @candidate_keys EventDispatchCandidate.__struct__() |> Map.keys()
  @candidate_key_count length(@candidate_keys)

  @spec load(module(), module(), DateTime.t()) ::
          {:ok, [EventDispatchCandidate.t()], [Event.t()]}
          | {:error, :event_dispatch_failed | :invalid_event_dispatch_cycle}
  def load(dispatches, events, %DateTime{} = now) do
    with {:ok, candidates} <- list_candidates(dispatches, now),
         {:ok, loaded} <- load_events(candidates, events, now, nil, [], 0) do
      {:ok, candidates, loaded}
    end
  end

  def load(_dispatches, _events, _now), do: {:error, :invalid_event_dispatch_cycle}

  defp list_candidates(dispatches, now) do
    case dispatches.list_available(now) do
      {:ok, candidates} when is_list(candidates) ->
        {:ok, candidates}

      {:error, reason} when reason in [:invalid_dispatch, :storage_unavailable] ->
        {:error, :event_dispatch_failed}

      _failure ->
        {:error, :invalid_event_dispatch_cycle}
    end
  rescue
    _error -> {:error, :event_dispatch_failed}
  catch
    _kind, _reason -> {:error, :event_dispatch_failed}
  end

  defp load_events([], _events, _now, _previous, loaded, _count),
    do: {:ok, Enum.reverse(loaded)}

  defp load_events(
         [%EventDispatchCandidate{} = candidate | candidates],
         events,
         now,
         previous,
         loaded,
         count
       )
       when count < @max_candidates do
    with :ok <- validate_candidate(candidate, now, previous),
         {:ok, %Event{} = event} <- fetch_event(events, candidate.event_id),
         true <- event.id == candidate.event_id do
      load_events(candidates, events, now, candidate, [event | loaded], count + 1)
    else
      {:error, :event_dispatch_failed} = error -> error
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp load_events(_candidates, _events, _now, _previous, _loaded, _count),
    do: {:error, :invalid_event_dispatch_cycle}

  defp fetch_event(events, event_id) do
    case events.fetch(event_id) do
      {:ok, %Event{} = event} ->
        {:ok, event}

      {:error, reason}
      when reason in [:event_not_found, :invalid_event_record, :storage_unavailable] ->
        {:error, :event_dispatch_failed}

      _failure ->
        {:error, :invalid_event_dispatch_cycle}
    end
  rescue
    _error -> {:error, :event_dispatch_failed}
  catch
    _kind, _reason -> {:error, :event_dispatch_failed}
  end

  defp validate_candidate(candidate, now, previous) do
    with true <- exact_candidate?(candidate),
         :ok <- Validator.validate_id(candidate.event_id),
         :ok <- DateTimeValidator.validate_storage_utc(candidate.enqueued_at),
         true <- DateTime.compare(candidate.enqueued_at, now) in [:lt, :eq],
         true <- after_previous?(candidate, previous) do
      :ok
    else
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp after_previous?(_candidate, nil), do: true

  defp after_previous?(candidate, previous) do
    case DateTime.compare(candidate.enqueued_at, previous.enqueued_at) do
      :gt -> true
      :eq -> candidate.event_id > previous.event_id
      :lt -> false
    end
  end

  defp exact_candidate?(candidate) do
    map_size(candidate) == @candidate_key_count and
      Enum.all?(@candidate_keys, &Map.has_key?(candidate, &1))
  end
end

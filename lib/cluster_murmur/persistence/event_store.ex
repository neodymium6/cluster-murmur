defmodule ClusterMurmur.Persistence.EventStore do
  @moduledoc """
  Persists and restores immutable bounded events through a narrow store API.

  Repeating the exact event returns the committed redacted record. Reusing an
  event ID for different content is a stable conflict and never replaces the
  first committed fact.
  """

  alias ClusterMurmur.Events.{BoundedJsonDecoder, Event, Validator}
  alias ClusterMurmur.Persistence.EventRecord
  alias ClusterMurmur.Repo

  @max_encoded_payload_bytes 512 * 1_024

  @event_fields [
    :id,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :previous,
    :current,
    :dedupe_key,
    :correlation_key,
    :facts,
    :labels,
    :occurred_at,
    :observed_at
  ]

  @type error ::
          :event_conflict
          | :event_not_found
          | :invalid_event
          | :invalid_event_id
          | :invalid_event_record
          | :storage_unavailable

  @doc "Inserts one event or restores the identical record already committed for its ID."
  @spec insert(term()) :: {:ok, EventRecord.t()} | {:error, error()}
  def insert(event) do
    changeset = EventRecord.changeset(%EventRecord{}, event)

    if changeset.valid? do
      persist(changeset)
    else
      {:error, :invalid_event}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Restores one validated bounded event by its complete ID."
  @spec fetch(term()) :: {:ok, Event.t()} | {:error, error()}
  def fetch(id) do
    case Validator.validate_id(id) do
      :ok -> fetch_persisted(id)
      {:error, :invalid_event} -> {:error, :invalid_event_id}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp persist(changeset) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    case Repo.transaction(fn -> insert_then_restore(changeset, candidate) end) do
      {:ok, %EventRecord{} = record} -> {:ok, record}
      {:error, :event_conflict} -> {:error, :event_conflict}
      {:error, :invalid_event} -> {:error, :invalid_event}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp insert_then_restore(changeset, candidate) do
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:id]) do
      {:ok, _inserted_or_conflicted} -> restore_identical(candidate)
      {:error, _changeset} -> Repo.rollback(:invalid_event)
    end
  end

  defp restore_identical(candidate) do
    case Repo.get(EventRecord, candidate.id) do
      %EventRecord{} = persisted ->
        if identical_event?(persisted, candidate),
          do: persisted,
          else: Repo.rollback(:event_conflict)

      nil ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp identical_event?(persisted, candidate) do
    Map.take(persisted, @event_fields) == Map.take(candidate, @event_fields)
  end

  defp fetch_persisted(id) do
    case Repo.get(EventRecord, id) do
      %EventRecord{} = record -> decode_record(record)
      nil -> {:error, :event_not_found}
    end
  end

  defp decode_record(record) do
    with :ok <- validate_encoded_payload(record),
         {:ok, budget} <- initial_decode_budget(record),
         {:ok, previous, budget} <- decode_optional(record.previous, budget),
         {:ok, current, budget} <- decode_optional(record.current, budget),
         {:ok, facts, budget} <- BoundedJsonDecoder.decode(record.facts, budget),
         {:ok, labels, _budget} <- BoundedJsonDecoder.decode(record.labels, budget) do
      event = %Event{
        id: record.id,
        type: record.type,
        source: record.source,
        subject: record.subject,
        group: record.group,
        severity: record.severity,
        previous: previous,
        current: current,
        occurred_at: record.occurred_at,
        observed_at: record.observed_at,
        dedupe_key: record.dedupe_key,
        correlation_key: record.correlation_key,
        facts: facts,
        labels: labels
      }

      case Validator.validate(event) do
        :ok -> {:ok, event}
        {:error, :invalid_event} -> {:error, :invalid_event_record}
      end
    else
      _failure -> {:error, :invalid_event_record}
    end
  end

  defp validate_encoded_payload(record) do
    Enum.reduce_while([:previous, :current, :facts, :labels], 0, fn field, total ->
      case Map.fetch!(record, field) do
        nil -> {:cont, total}
        value when is_binary(value) -> {:cont, total + byte_size(value)}
        _invalid -> {:halt, :invalid}
      end
    end)
    |> case do
      bytes when is_integer(bytes) and bytes <= @max_encoded_payload_bytes -> :ok
      _invalid -> {:error, :invalid_event_record}
    end
  end

  defp initial_decode_budget(record) do
    BoundedJsonDecoder.initial_budget([
      record.id,
      record.type,
      record.source,
      record.subject,
      record.group,
      record.severity,
      record.dedupe_key,
      record.correlation_key
    ])
  end

  defp decode_optional(nil, budget), do: BoundedJsonDecoder.consume_null(budget)

  defp decode_optional(encoded, budget) do
    case BoundedJsonDecoder.decode(encoded, budget) do
      {:ok, nil, _budget} -> {:error, :invalid_event_record}
      result -> result
    end
  end
end

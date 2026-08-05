defmodule ClusterMurmur.Persistence.EntityStateRecordValidator do
  @moduledoc """
  Validates and decodes exact loaded observation entity-state records.

  Durable JSON is decoded through the shared bounded event-value boundary
  before the reconstructed domain state is accepted.
  """

  alias ClusterMurmur.Events.BoundedJsonDecoder
  alias ClusterMurmur.Observations.{EntityState, EntityStateValidator}
  alias ClusterMurmur.Persistence.EntityStateRecord

  @record_keys EntityStateRecord.__struct__() |> Map.keys()
  @record_key_count length(@record_keys)
  @loaded_metadata Ecto.put_meta(%EntityStateRecord{}, state: :loaded).__meta__
  @max_encoded_payload_bytes 128 * 1_024

  @type error :: :invalid_entity_state_record

  @doc "Validates one exact loaded record through the complete domain boundary."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(record) do
    case decode(record) do
      {:ok, %EntityState{}} -> :ok
      {:error, :invalid_entity_state_record} = error -> error
    end
  end

  @doc "Decodes one exact loaded record into a validated entity state."
  @spec decode(term()) :: {:ok, EntityState.t()} | {:error, error()}
  def decode(%EntityStateRecord{} = record) do
    with true <- exact_loaded?(record),
         true <- encoded_payload_size(record) <= @max_encoded_payload_bytes,
         {:ok, budget} <- BoundedJsonDecoder.initial_budget([record.source, record.subject]),
         {:ok, facts, budget} <- BoundedJsonDecoder.decode(record.facts, budget),
         {:ok, labels, _budget} <- BoundedJsonDecoder.decode(record.labels, budget),
         true <- is_map(facts) and not is_struct(facts),
         true <- is_map(labels) and not is_struct(labels) do
      state = %EntityState{
        source: record.source,
        subject: record.subject,
        current_state: record.current_state,
        pending_state: record.pending_state,
        consecutive_count: record.consecutive_count,
        last_observed_at: record.last_observed_at,
        last_changed_at: record.last_changed_at,
        facts: facts,
        labels: labels
      }

      if EntityStateValidator.validate(state) == :ok,
        do: {:ok, state},
        else: {:error, :invalid_entity_state_record}
    else
      _failure -> {:error, :invalid_entity_state_record}
    end
  rescue
    _error -> {:error, :invalid_entity_state_record}
  catch
    _kind, _reason -> {:error, :invalid_entity_state_record}
  end

  def decode(_record), do: {:error, :invalid_entity_state_record}

  defp exact_loaded?(record) do
    map_size(record) == @record_key_count and Enum.all?(@record_keys, &Map.has_key?(record, &1)) and
      record.__meta__ == @loaded_metadata
  end

  defp encoded_payload_size(record) do
    Enum.reduce_while([record.facts, record.labels], 0, fn
      value, total when is_binary(value) -> {:cont, total + byte_size(value)}
      _invalid, _total -> {:halt, @max_encoded_payload_bytes + 1}
    end)
  end
end

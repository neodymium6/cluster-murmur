defmodule ClusterMurmur.Ingestion.EventEnvelopeValidator do
  @moduledoc """
  Validates one normalized external event against source-scoped allowlists.

  Facts are flat JSON scalars and labels are flat strings. The shared event
  validator supplies the existing aggregate text, node, number, and UTC time
  bounds without granting this boundary any persistence or execution ability.
  """

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Config.Value
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Ingestion.EventEnvelope

  @envelope_keys EventEnvelope.__struct__() |> Map.keys()
  @envelope_key_count length(@envelope_keys)
  @severities ~w(info warning critical)
  @max_idempotency_key_bytes 256

  @type error :: :invalid_external_event

  @doc "Validates one exact normalized external event and its configured source policy."
  @spec validate(term(), term()) :: :ok | {:error, error()}
  def validate(%EventEnvelope{} = envelope, %ExternalIngestion{} = configuration) do
    with true <- exact_envelope?(envelope),
         :ok <- ExternalIngestion.validate(configuration),
         {:ok, source} <- Map.fetch(configuration.sources, envelope.source),
         true <- valid_idempotency_key?(envelope.idempotency_key),
         true <- MapSet.member?(source.event_types, envelope.type),
         true <- MapSet.member?(source.groups, envelope.group),
         true <- MapSet.member?(source.subjects, envelope.subject),
         true <- envelope.severity in @severities,
         true <- allowed_keys?(envelope.facts, source.fact_keys),
         true <- allowed_keys?(envelope.labels, source.label_keys),
         true <- flat_facts?(envelope.facts),
         true <- string_labels?(envelope.labels),
         :ok <- Validator.validate(as_event(envelope)) do
      :ok
    else
      _failure -> {:error, :invalid_external_event}
    end
  rescue
    _error -> {:error, :invalid_external_event}
  catch
    _kind, _reason -> {:error, :invalid_external_event}
  end

  def validate(_envelope, _configuration), do: {:error, :invalid_external_event}

  defp exact_envelope?(envelope) do
    map_size(envelope) == @envelope_key_count and
      Enum.all?(@envelope_keys, &Map.has_key?(envelope, &1))
  end

  defp allowed_keys?(value, allowed) when is_map(value) and not is_struct(value),
    do: value |> Map.keys() |> Enum.all?(&MapSet.member?(allowed, &1))

  defp allowed_keys?(_value, _allowed), do: false

  defp flat_facts?(facts),
    do: Enum.all?(facts, fn {_key, value} -> scalar?(value) end)

  defp scalar?(value),
    do: is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value)

  defp string_labels?(labels),
    do: Enum.all?(labels, fn {_key, value} -> is_binary(value) end)

  defp valid_idempotency_key?(value)
       when is_binary(value) and byte_size(value) <= @max_idempotency_key_bytes,
       do: match?({:ok, ^value}, Value.id(value))

  defp valid_idempotency_key?(_value), do: false

  defp as_event(envelope) do
    %Event{
      id: envelope.idempotency_key,
      type: envelope.type,
      source: envelope.source,
      subject: envelope.subject,
      group: envelope.group,
      severity: envelope.severity,
      previous: nil,
      current: nil,
      occurred_at: envelope.occurred_at,
      observed_at: nil,
      dedupe_key: envelope.idempotency_key,
      correlation_key: nil,
      facts: envelope.facts,
      labels: envelope.labels
    }
  end
end

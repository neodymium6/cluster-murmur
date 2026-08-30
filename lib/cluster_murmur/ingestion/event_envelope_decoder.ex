defmodule ClusterMurmur.Ingestion.EventEnvelopeDecoder do
  @moduledoc """
  Decodes one exact bounded JSON body into a validated external envelope.

  Duplicate or unknown fields, trailing input, nested facts, non-string labels,
  non-UTC timestamps, and values outside the configured source policy fail as
  one value-free error.
  """

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Events.BoundedJsonDecoder
  alias ClusterMurmur.Ingestion.{EventEnvelope, EventEnvelopeValidator}

  @max_body_bytes 64 * 1_024
  @document_keys [
    "facts",
    "group",
    "idempotency_key",
    "labels",
    "occurred_at",
    "severity",
    "source",
    "subject",
    "type"
  ]

  @type error :: :invalid_external_event_body

  @doc "Decodes and allowlist-validates one complete JSON request body."
  @spec decode(term(), term()) :: {:ok, EventEnvelope.t()} | {:error, error()}
  def decode(body, %ExternalIngestion{} = configuration)
      when is_binary(body) and byte_size(body) in 1..@max_body_bytes do
    with {:ok, budget} <- BoundedJsonDecoder.initial_budget([]),
         {:ok, document, _budget} <- BoundedJsonDecoder.decode(body, budget),
         true <- exact_document?(document),
         {:ok, occurred_at} <- parse_occurred_at(document["occurred_at"]),
         envelope = build(document, occurred_at),
         :ok <- EventEnvelopeValidator.validate(envelope, configuration) do
      {:ok, envelope}
    else
      _failure -> {:error, :invalid_external_event_body}
    end
  rescue
    _error -> {:error, :invalid_external_event_body}
  catch
    _kind, _reason -> {:error, :invalid_external_event_body}
  end

  def decode(_body, _configuration), do: {:error, :invalid_external_event_body}

  defp exact_document?(document) when is_map(document) and not is_struct(document) do
    map_size(document) == length(@document_keys) and
      Enum.all?(@document_keys, &Map.has_key?(document, &1))
  end

  defp exact_document?(_document), do: false

  defp parse_occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, occurred_at, 0} -> {:ok, occurred_at}
      _invalid -> {:error, :invalid_external_event_body}
    end
  end

  defp parse_occurred_at(_value), do: {:error, :invalid_external_event_body}

  defp build(document, occurred_at) do
    %EventEnvelope{
      idempotency_key: document["idempotency_key"],
      type: document["type"],
      source: document["source"],
      subject: document["subject"],
      group: document["group"],
      severity: document["severity"],
      occurred_at: occurred_at,
      facts: document["facts"],
      labels: document["labels"]
    }
  end
end

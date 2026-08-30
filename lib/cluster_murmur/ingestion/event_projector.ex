defmodule ClusterMurmur.Ingestion.EventProjector do
  @moduledoc """
  Projects one allowlisted external envelope into a deterministic event.

  The source and idempotency key determine identity. Reusing that identity for
  changed content preserves the event ID so immutable persistence can reject the
  conflict. No persistence, clock read, trigger, or external action occurs here.
  """

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Ingestion.{EventEnvelope, EventEnvelopeValidator}

  @type error :: :invalid_external_event

  @doc "Projects one validated envelope into an immutable bounded event."
  @spec project(term(), term()) :: {:ok, Event.t()} | {:error, error()}
  def project(%EventEnvelope{} = envelope, %ExternalIngestion{} = configuration) do
    with :ok <- EventEnvelopeValidator.validate(envelope, configuration) do
      event = build(envelope)

      case Validator.validate(event) do
        :ok -> {:ok, event}
        {:error, :invalid_event} -> {:error, :invalid_external_event}
      end
    else
      _failure -> {:error, :invalid_external_event}
    end
  rescue
    _error -> {:error, :invalid_external_event}
  catch
    _kind, _reason -> {:error, :invalid_external_event}
  end

  def project(_envelope, _configuration), do: {:error, :invalid_external_event}

  defp build(envelope) do
    identity = digest([envelope.source, envelope.idempotency_key])

    %Event{
      id: "external-" <> identity,
      type: envelope.type,
      source: envelope.source,
      subject: envelope.subject,
      group: envelope.group,
      severity: envelope.severity,
      previous: nil,
      current: nil,
      occurred_at: normalize_precision(envelope.occurred_at),
      observed_at: nil,
      dedupe_key: "external:" <> identity,
      correlation_key: nil,
      facts: envelope.facts,
      labels: envelope.labels
    }
  end

  defp digest(parts) do
    :crypto.hash(:sha256, Enum.intersperse(parts, <<0>>))
    |> Base.encode16(case: :lower)
  end

  defp normalize_precision(%DateTime{microsecond: {value, _precision}} = occurred_at),
    do: %{occurred_at | microsecond: {value, 6}}
end

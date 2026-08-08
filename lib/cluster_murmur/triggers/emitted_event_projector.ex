defmodule ClusterMurmur.Triggers.EmittedEventProjector do
  @moduledoc """
  Purely projects one configured trigger template into a bounded event.

  The event identity and occurrence time are derived from the scheduled UTC
  instant rather than an execution attempt. Retrying the same scheduled
  version with the exact same configured template therefore produces the same
  immutable event. Template drift deliberately preserves the event ID so
  idempotent persistence rejects changed facts for that durable version.
  """

  alias ClusterMurmur.Config.Value
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Triggers.EmittedEvent

  @kinds [:schedule, :stochastic]
  @template_keys EmittedEvent.__struct__() |> Map.keys()
  @template_key_count length(@template_keys)

  @type kind :: :schedule | :stochastic
  @type error :: :invalid_emitted_event

  @doc "Returns one event for an exact configured template and schedule version."
  @spec project(term(), term(), term(), term()) ::
          {:ok, Event.t()} | {:error, error()}
  def project(kind, trigger_id, %EmittedEvent{} = template, %DateTime{} = scheduled_at) do
    with true <- kind in @kinds,
         {:ok, trigger_id} <- Value.id(trigger_id),
         :ok <- validate_template(template),
         :ok <- DateTimeValidator.validate_storage_utc(scheduled_at) do
      event = build(kind, trigger_id, template, normalize_precision(scheduled_at))

      case Validator.validate(event) do
        :ok -> {:ok, event}
        {:error, :invalid_event} -> {:error, :invalid_emitted_event}
      end
    else
      _failure -> {:error, :invalid_emitted_event}
    end
  rescue
    _error -> {:error, :invalid_emitted_event}
  catch
    _kind, _reason -> {:error, :invalid_emitted_event}
  end

  def project(_kind, _trigger_id, _template, _scheduled_at),
    do: {:error, :invalid_emitted_event}

  defp validate_template(template) do
    with true <- exact_template?(template),
         {:ok, _type} <- Value.id(template.type),
         {:ok, _group} <- Value.id(template.group),
         {:ok, _subject} <- Value.id(template.subject) do
      :ok
    else
      _failure -> {:error, :invalid_emitted_event}
    end
  end

  defp build(kind, trigger_id, template, scheduled_at) do
    source = Atom.to_string(kind)

    %Event{
      id: source <> "-" <> digest([trigger_id, scheduled_at_key(scheduled_at)]),
      type: template.type,
      source: source,
      subject: template.subject,
      group: template.group,
      severity: "info",
      previous: nil,
      current: nil,
      occurred_at: scheduled_at,
      observed_at: nil,
      dedupe_key: source <> ":" <> digest([trigger_id]),
      correlation_key: nil,
      facts: %{},
      labels: %{"trigger_id" => trigger_id, "trigger_kind" => source}
    }
  end

  defp scheduled_at_key(scheduled_at),
    do: Integer.to_string(DateTime.to_unix(scheduled_at, :microsecond))

  defp digest(parts) do
    :crypto.hash(:sha256, Enum.intersperse(parts, <<0>>))
    |> Base.encode16(case: :lower)
  end

  defp normalize_precision(%DateTime{microsecond: {value, _precision}} = scheduled_at),
    do: %{scheduled_at | microsecond: {value, 6}}

  defp exact_template?(template) do
    map_size(template) == @template_key_count and
      Enum.all?(@template_keys, &Map.has_key?(template, &1))
  end
end

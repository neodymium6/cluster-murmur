defmodule ClusterMurmur.Generation.FallbackGenerator do
  @moduledoc """
  Generates one deterministic safe message from an application-confirmed event.

  One neutral template confirms only that a validated event was recorded.
  Arbitrary types, subjects, facts, labels, identifiers, and provider errors are
  never interpreted or interpolated into output. The generator is pure and does
  not read a clock, call an LLM, access storage, or publish a message.
  """

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Events.Validator, as: EventValidator
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  @content "A confirmed event was recorded."

  @type error :: :invalid_datetime | :invalid_event | :invalid_message

  @doc "Builds one validated fallback message at an injected UTC instant."
  @spec generate(term(), term(), term(), term()) :: {:ok, Message.t()} | {:error, error()}
  def generate(event, conversation_id, persona_id, inserted_at) do
    with :ok <- EventValidator.validate(event),
         :ok <- validate_timeline(event, inserted_at),
         message <- build_message(event, conversation_id, persona_id, inserted_at),
         :ok <- MessageValidator.validate(message) do
      {:ok, message}
    else
      {:error, :invalid_event} -> {:error, :invalid_event}
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      {:error, :invalid_message} -> {:error, :invalid_message}
    end
  rescue
    _error -> {:error, :invalid_message}
  catch
    _kind, _reason -> {:error, :invalid_message}
  end

  defp validate_timeline(%Event{} = event, inserted_at) do
    latest_event_at = latest_event_at(event)

    if DateTimeValidator.validate_storage_utc(inserted_at) == :ok and
         DateTime.compare(inserted_at, latest_event_at) in [:gt, :eq],
       do: :ok,
       else: {:error, :invalid_datetime}
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  defp latest_event_at(%Event{observed_at: nil, occurred_at: occurred_at}), do: occurred_at

  defp latest_event_at(%Event{observed_at: observed_at, occurred_at: occurred_at}) do
    if DateTime.compare(observed_at, occurred_at) == :lt, do: occurred_at, else: observed_at
  end

  defp build_message(_event, conversation_id, persona_id, inserted_at) do
    %Message{
      conversation_id: conversation_id,
      persona_id: persona_id,
      origin: :fallback,
      content: @content,
      discord_message_id: nil,
      inserted_at: inserted_at
    }
  end
end

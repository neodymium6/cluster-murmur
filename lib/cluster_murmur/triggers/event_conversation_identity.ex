defmodule ClusterMurmur.Triggers.EventConversationIdentity do
  @moduledoc """
  Derives one retry-stable conversation ID from an exact event-trigger match.

  The identity contains no event facts and is deterministic for one immutable
  event ID, trigger ID, and canonical execution instant.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerValidator}

  @type error :: :invalid_event_conversation_identity

  @doc "Derives one validated deterministic event conversation ID."
  @spec derive(term(), term(), term()) :: {:ok, String.t()} | {:error, error()}
  def derive(%Event{} = event, %EventTrigger{} = trigger, executed_at) do
    with :ok <- Validator.validate(event),
         :ok <- EventTriggerValidator.validate(trigger),
         :ok <- DateTimeValidator.validate_storage_utc(executed_at),
         true <- not_before_event?(executed_at, event) do
      digest =
        :crypto.hash(
          :sha256,
          [event.id, <<0>>, trigger.id, <<0>>, DateTime.to_iso8601(executed_at)]
        )
        |> Base.encode16(case: :lower)

      {:ok, "conversation-" <> digest}
    else
      _failure -> {:error, :invalid_event_conversation_identity}
    end
  rescue
    _error -> {:error, :invalid_event_conversation_identity}
  catch
    _kind, _reason -> {:error, :invalid_event_conversation_identity}
  end

  def derive(_event, _trigger, _executed_at),
    do: {:error, :invalid_event_conversation_identity}

  defp not_before_event?(executed_at, event) do
    latest =
      case event.observed_at do
        nil -> event.occurred_at
        observed_at -> later(event.occurred_at, observed_at)
      end

    DateTime.compare(executed_at, latest) in [:eq, :gt]
  end

  defp later(left, right), do: if(DateTime.compare(left, right) == :lt, do: right, else: left)
end

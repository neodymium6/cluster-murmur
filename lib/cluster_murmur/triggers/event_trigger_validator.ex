defmodule ClusterMurmur.Triggers.EventTriggerValidator do
  @moduledoc """
  Validates one runtime event trigger without retaining or exposing its values.

  Configuration parsing constructs this closed shape, while runtime consumers
  revalidate it before making matching, cooldown, or persistence decisions.
  """

  alias ClusterMurmur.Events.{Matcher, MatcherEvaluator}
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Triggers.EventTrigger

  @event_trigger_keys EventTrigger.__struct__() |> Map.keys()
  @event_trigger_key_count length(@event_trigger_keys)
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_cooldown_ms DomainLimits.max_interval_ms()

  @type error :: :invalid_trigger | :invalid_trigger_matcher

  @doc "Validates one exact event-trigger shape and its bounded matcher."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(
        %EventTrigger{
          id: id,
          matcher: %Matcher{} = matcher,
          action: :start_conversation,
          binding: binding,
          cooldown_ms: cooldown_ms
        } = trigger
      )
      when is_binary(id) and is_binary(binding) and is_integer(cooldown_ms) and cooldown_ms >= 0 and
             cooldown_ms <= @max_cooldown_ms do
    with true <- exact_keys?(trigger),
         true <- valid_id?(id),
         true <- valid_id?(binding),
         :ok <- MatcherEvaluator.validate(matcher) do
      :ok
    else
      {:error, :invalid_matcher} -> {:error, :invalid_trigger_matcher}
      _failure -> {:error, :invalid_trigger}
    end
  rescue
    _error -> {:error, :invalid_trigger}
  catch
    _kind, _reason -> {:error, :invalid_trigger}
  end

  def validate(_trigger), do: {:error, :invalid_trigger}

  defp exact_keys?(trigger) do
    map_size(trigger) == @event_trigger_key_count and
      Enum.all?(@event_trigger_keys, &Map.has_key?(trigger, &1))
  end

  defp valid_id?(value) do
    byte_size(value) <= @max_id_bytes and String.valid?(value) and
      Regex.match?(@id_pattern, value)
  end
end

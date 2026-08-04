defmodule ClusterMurmur.Triggers.EventSelector do
  @moduledoc """
  Selects event triggers whose bounded matchers match one event.

  Selection is deterministic and side-effect free. Cooldown and execution
  bookkeeping remain later persistence-backed policy stages.
  """

  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.MatcherEvaluator
  alias ClusterMurmur.Triggers.EventTrigger

  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_triggers 256

  @type error ::
          :duplicate_trigger
          | :invalid_event
          | :invalid_trigger
          | :invalid_trigger_matcher
          | :too_many_triggers

  @doc "Returns matching event triggers in ascending ID order."
  @spec select(term(), term()) :: {:ok, [EventTrigger.t()]} | {:error, error()}
  def select(triggers, event) when is_list(triggers) do
    with :ok <- validate_collection(triggers),
         {:ok, triggers} <- validate_and_sort(triggers),
         :ok <- reject_duplicate_ids(triggers) do
      select_matching(triggers, event, [])
    end
  end

  def select(_triggers, _event), do: {:error, :invalid_trigger}

  defp validate_collection(triggers), do: validate_collection(triggers, 0)

  defp validate_collection([], _count), do: :ok

  defp validate_collection([_trigger | _triggers], @max_triggers),
    do: {:error, :too_many_triggers}

  defp validate_collection([_trigger | triggers], count),
    do: validate_collection(triggers, count + 1)

  defp validate_collection(_improper_tail, _count), do: {:error, :invalid_trigger}

  defp validate_and_sort(triggers) do
    triggers
    |> Enum.reduce_while({:ok, []}, fn trigger, {:ok, validated} ->
      case validate_trigger(trigger) do
        :ok -> {:cont, {:ok, [trigger | validated]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.sort_by(validated, & &1.id)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_trigger(%EventTrigger{
         id: id,
         matcher: %Matcher{},
         action: :start_conversation,
         binding: binding,
         cooldown_ms: cooldown_ms
       })
       when is_binary(id) and is_binary(binding) and is_integer(cooldown_ms) and cooldown_ms >= 0 do
    if valid_id?(id) and valid_id?(binding), do: :ok, else: {:error, :invalid_trigger}
  end

  defp validate_trigger(_trigger), do: {:error, :invalid_trigger}

  defp valid_id?(value), do: String.valid?(value) and Regex.match?(@id_pattern, value)

  defp reject_duplicate_ids([]), do: :ok

  defp reject_duplicate_ids([first | triggers]),
    do: reject_duplicate_ids(triggers, first.id)

  defp reject_duplicate_ids([], _previous_id), do: :ok

  defp reject_duplicate_ids([trigger | _triggers], previous_id) when trigger.id == previous_id,
    do: {:error, :duplicate_trigger}

  defp reject_duplicate_ids([trigger | triggers], _previous_id),
    do: reject_duplicate_ids(triggers, trigger.id)

  defp select_matching([], _event, selected), do: {:ok, Enum.reverse(selected)}

  defp select_matching([trigger | triggers], event, selected) do
    case MatcherEvaluator.match(trigger.matcher, event) do
      {:ok, true} -> select_matching(triggers, event, [trigger | selected])
      {:ok, false} -> select_matching(triggers, event, selected)
      {:error, :invalid_event} -> {:error, :invalid_event}
      {:error, :invalid_matcher} -> {:error, :invalid_trigger_matcher}
    end
  end
end

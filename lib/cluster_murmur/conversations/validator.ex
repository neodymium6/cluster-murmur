defmodule ClusterMurmur.Conversations.Validator do
  @moduledoc """
  Validates one exact, bounded runtime conversation without exposing values.

  Generated messages remain outside this boundary until the project defines a
  typed message value. Conversation metadata may therefore carry only an empty
  message projection.
  """

  alias ClusterMurmur.Conversations.Conversation
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Events.Validator, as: EventValidator

  @conversation_keys Conversation.__struct__() |> Map.keys()
  @conversation_key_count length(@conversation_keys)
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @statuses [:starting, :generating, :waiting, :completed, :cancelled, :failed]
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_safe_integer DomainLimits.max_safe_integer()
  @max_participants 256

  @type error :: :invalid_conversation

  @doc "Validates one exact runtime conversation and its bounded metadata."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(
        %Conversation{
          id: id,
          root_event_id: root_event_id,
          status: status,
          started_at: started_at,
          last_message_at: last_message_at,
          turn_count: turn_count,
          llm_call_count: llm_call_count,
          participants: participants,
          messages: []
        } = conversation
      )
      when status in @statuses and is_integer(turn_count) and is_integer(llm_call_count) and
             turn_count in 0..@max_safe_integer and llm_call_count in 0..@max_safe_integer do
    with true <- exact_conversation?(conversation),
         true <- valid_portable_id?(id),
         :ok <- EventValidator.validate_id(root_event_id),
         :ok <- validate_datetime(started_at),
         :ok <- validate_optional_later_datetime(last_message_at, started_at),
         true <- valid_participants?(participants) do
      :ok
    else
      _failure -> {:error, :invalid_conversation}
    end
  rescue
    _error -> {:error, :invalid_conversation}
  catch
    _kind, _reason -> {:error, :invalid_conversation}
  end

  def validate(_conversation), do: {:error, :invalid_conversation}

  defp exact_conversation?(conversation) do
    map_size(conversation) == @conversation_key_count and
      Enum.all?(@conversation_keys, &Map.has_key?(conversation, &1))
  end

  defp validate_datetime(datetime) do
    case DateTimeValidator.validate_storage_utc(datetime) do
      :ok -> :ok
      {:error, :invalid_datetime} -> {:error, :invalid_conversation}
    end
  end

  defp validate_optional_later_datetime(nil, _started_at), do: :ok

  defp validate_optional_later_datetime(last_message_at, started_at) do
    with :ok <- validate_datetime(last_message_at),
         comparison when comparison in [:gt, :eq] <-
           DateTime.compare(last_message_at, started_at) do
      :ok
    else
      _failure -> {:error, :invalid_conversation}
    end
  end

  defp valid_participants?(participants) when is_list(participants) do
    case bounded_unique_participants(participants, MapSet.new(), 0) do
      {:ok, _seen} -> true
      :error -> false
    end
  end

  defp valid_participants?(_participants), do: false

  defp bounded_unique_participants([], seen, _count), do: {:ok, seen}

  defp bounded_unique_participants([participant | rest], seen, count)
       when count < @max_participants do
    if valid_portable_id?(participant) and not MapSet.member?(seen, participant) do
      bounded_unique_participants(rest, MapSet.put(seen, participant), count + 1)
    else
      :error
    end
  end

  defp bounded_unique_participants(_participants, _seen, _count), do: :error

  defp valid_portable_id?(value)
       when is_binary(value) and byte_size(value) in 1..@max_id_bytes do
    String.valid?(value) and Regex.match?(@id_pattern, value)
  end

  defp valid_portable_id?(_value), do: false
end

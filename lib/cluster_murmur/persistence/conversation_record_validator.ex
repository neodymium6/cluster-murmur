defmodule ClusterMurmur.Persistence.ConversationRecordValidator do
  @moduledoc """
  Validates exact loaded conversation records without exposing their values.
  """

  alias ClusterMurmur.Conversations.{Conversation, Validator}
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.ConversationRecord

  @record_keys ConversationRecord.__struct__() |> Map.keys()
  @record_key_count length(@record_keys)
  @loaded_metadata Ecto.put_meta(%ConversationRecord{}, state: :loaded).__meta__

  @type error :: :invalid_conversation_record

  @doc "Validates one exact loaded record and its closed lifecycle correlation."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%ConversationRecord{} = record) do
    if exact_loaded?(record) and valid_runtime_projection?(record) and valid_lifecycle?(record),
      do: :ok,
      else: {:error, :invalid_conversation_record}
  rescue
    _error -> {:error, :invalid_conversation_record}
  catch
    _kind, _reason -> {:error, :invalid_conversation_record}
  end

  def validate(_record), do: {:error, :invalid_conversation_record}

  @doc "Validates one exact loaded record that remains in pristine starting state."
  @spec validate_started(term()) :: :ok | {:error, error()}
  def validate_started(
        %ConversationRecord{
          status: :starting,
          turn_count: 0,
          llm_call_count: 0,
          completed_at: nil
        } = record
      ),
      do: validate(record)

  def validate_started(_record), do: {:error, :invalid_conversation_record}

  @doc "Validates one exact loaded record in any nonterminal state."
  @spec validate_active(term()) :: :ok | {:error, error()}
  def validate_active(%ConversationRecord{status: status, completed_at: nil} = record)
      when status in [:starting, :generating, :waiting],
      do: validate(record)

  def validate_active(_record), do: {:error, :invalid_conversation_record}

  defp exact_loaded?(record) do
    map_size(record) == @record_key_count and Enum.all?(@record_keys, &Map.has_key?(record, &1)) and
      record.__meta__ == @loaded_metadata
  end

  defp valid_runtime_projection?(record) do
    loaded_datetime?(record.started_at) and
      Validator.validate(%Conversation{
        id: record.id,
        root_event_id: record.root_event_id,
        status: record.status,
        started_at: record.started_at,
        last_message_at: nil,
        turn_count: record.turn_count,
        llm_call_count: record.llm_call_count,
        participants: [],
        messages: []
      }) == :ok
  end

  defp valid_lifecycle?(%ConversationRecord{status: status, completed_at: nil})
       when status in [:starting, :generating, :waiting],
       do: true

  defp valid_lifecycle?(%ConversationRecord{status: status} = record)
       when status in [:completed, :cancelled, :failed] do
    loaded_datetime?(record.completed_at) and
      DateTime.compare(record.completed_at, record.started_at) in [:gt, :eq]
  end

  defp valid_lifecycle?(_record), do: false

  defp loaded_datetime?(%DateTime{microsecond: {_value, 6}} = datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp loaded_datetime?(_datetime), do: false
end

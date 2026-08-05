defmodule ClusterMurmur.Persistence.MessageRecordValidator do
  @moduledoc """
  Validates exact loaded message records without exposing their values.
  """

  alias ClusterMurmur.Messages.{Message, Validator}
  alias ClusterMurmur.Persistence.MessageRecord

  @record_keys MessageRecord.__struct__() |> Map.keys()
  @record_key_count length(@record_keys)
  @loaded_metadata Ecto.put_meta(%MessageRecord{}, state: :loaded).__meta__
  @max_sqlite_integer 9_223_372_036_854_775_807

  @type error :: :invalid_message_record

  @doc "Validates one exact loaded record through the complete runtime boundary."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%MessageRecord{} = record) do
    if exact_loaded?(record) and valid_surrogate_id?(record.id) and valid_projection?(record),
      do: :ok,
      else: {:error, :invalid_message_record}
  rescue
    _error -> {:error, :invalid_message_record}
  catch
    _kind, _reason -> {:error, :invalid_message_record}
  end

  def validate(_record), do: {:error, :invalid_message_record}

  defp exact_loaded?(record) do
    map_size(record) == @record_key_count and Enum.all?(@record_keys, &Map.has_key?(record, &1)) and
      record.__meta__ == @loaded_metadata
  end

  defp valid_surrogate_id?(id), do: is_integer(id) and id in 1..@max_sqlite_integer

  defp valid_projection?(record) do
    Validator.validate(%Message{
      conversation_id: record.conversation_id,
      persona_id: record.persona_id,
      origin: record.origin,
      content: record.content,
      discord_message_id: record.discord_message_id,
      inserted_at: record.inserted_at
    }) == :ok and loaded_datetime?(record.inserted_at)
  end

  defp loaded_datetime?(%DateTime{microsecond: {_value, 6}}), do: true
  defp loaded_datetime?(_datetime), do: false
end

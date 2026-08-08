defmodule ClusterMurmur.Conversations.MessageWindow do
  @moduledoc false

  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  @max_messages 12

  @spec append(term(), term()) :: {:ok, [Message.t()]} | {:error, :invalid_message_window}
  def append(messages, %Message{} = message) when is_list(messages) do
    if length(messages) <= @max_messages and
         Enum.all?(messages, &(MessageValidator.validate(&1) == :ok)) and
         MessageValidator.validate(message) == :ok do
      {:ok, Enum.take(messages ++ [message], -@max_messages)}
    else
      {:error, :invalid_message_window}
    end
  rescue
    _error -> {:error, :invalid_message_window}
  catch
    _kind, _reason -> {:error, :invalid_message_window}
  end

  def append(_messages, _message), do: {:error, :invalid_message_window}
end

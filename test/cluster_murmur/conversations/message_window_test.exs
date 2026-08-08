defmodule ClusterMurmur.Conversations.MessageWindowTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.MessageWindow
  alias ClusterMurmur.Messages.Message

  test "keeps the latest twelve messages when appending to a full valid window" do
    messages = Enum.map(1..12, &message/1)
    newest = message(13)

    assert {:ok, projected} = MessageWindow.append(messages, newest)
    assert length(projected) == 12
    assert Enum.map(projected, & &1.content) == Enum.map(2..13, &"message-#{&1}")
  end

  test "rejects oversized or malformed input windows" do
    messages = Enum.map(1..13, &message/1)

    assert MessageWindow.append(messages, message(14)) == {:error, :invalid_message_window}
    assert MessageWindow.append([nil], message(1)) == {:error, :invalid_message_window}
    assert MessageWindow.append([], nil) == {:error, :invalid_message_window}
  end

  defp message(index) do
    %Message{
      conversation_id: "conversation-1",
      persona_id: "persona-1",
      origin: :llm,
      content: "message-#{index}",
      discord_message_id: Integer.to_string(index),
      inserted_at: DateTime.add(~U[2026-08-07 02:00:00.000000Z], index, :second)
    }
  end
end

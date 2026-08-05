defmodule ClusterMurmur.Messages.ValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Messages.{Message, Validator}

  test "accepts bounded generated and published messages" do
    for message <- [
          message(:llm, nil),
          message(:fallback, "123456789012345678")
        ] do
      assert Validator.validate(message) == :ok
    end
  end

  test "rejects forged shapes, identifiers, origins, and timestamps" do
    valid = message(:llm, nil)

    invalid = [
      nil,
      Map.put(valid, :unexpected_private_value, "private"),
      %{valid | conversation_id: "invalid id"},
      %{valid | persona_id: ""},
      %{valid | origin: :system},
      %{valid | inserted_at: nil},
      %{valid | inserted_at: %{valid.inserted_at | hour: 24}},
      %{valid | inserted_at: DateTime.shift_zone!(valid.inserted_at, "Etc/GMT+1")}
    ]

    for rejected <- invalid do
      assert Validator.validate(rejected) == {:error, :invalid_message}
    end
  end

  test "enforces bounded nonblank UTF-8 content without unsafe output forms" do
    valid = message(:llm, nil)

    invalid_content = [
      "",
      " \n ",
      "\u200B",
      "\u200D",
      "\u0301",
      <<255>>,
      "hidden\0control",
      "hidden\tcontrol",
      "visit _https://example.invalid",
      "visit https://example.com",
      "visit ftp://example.invalid",
      "[click](https:localhost)",
      "[click](//localhost/path)",
      "data:text/plain,hello",
      "file:/etc/passwd",
      "visit WWW.EXAMPLE.COM",
      "visit example.com/path",
      "visit example.invalid",
      "visit example.com.",
      "visit example.com..",
      "visit example.com.1",
      "visit service.x/path",
      "visit example.\u200Dcom",
      "visit example.\u200Ccom",
      "visit example.\u0301com",
      "visit 192.0.2.10",
      "visit 例え.テスト",
      "visit 例え。テスト",
      "visit हिन्दी.भारत",
      "visit হিন্দি.ভারত",
      "hello @everyone",
      "hello @here",
      "hello <@123>",
      "hello <@!123>",
      "hello <@&123>",
      String.duplicate("a", 16 * 1_024 + 1)
    ]

    for content <- invalid_content do
      assert Validator.validate(%{valid | content: content}) == {:error, :invalid_message}
    end

    assert Validator.validate(%{valid | content: "A bounded line.\nA second line."}) == :ok
  end

  test "allows only an optional bounded decimal Discord message ID" do
    valid = message(:fallback, nil)

    for discord_id <- [
          "",
          "0",
          "000123",
          "message-1",
          "１２３",
          "18446744073709551616",
          String.duplicate("1", 33),
          123
        ] do
      assert Validator.validate(%{valid | discord_message_id: discord_id}) ==
               {:error, :invalid_message}
    end

    assert Validator.validate(%{
             valid
             | discord_message_id: "18446744073709551615"
           }) == :ok
  end

  test "validates content without requiring message metadata" do
    assert Validator.validate_content("The latest bounded fact is ready.") == :ok
    assert Validator.validate_content("https://example.invalid") == {:error, :invalid_message}
    assert Validator.validate_content(123) == {:error, :invalid_message}
  end

  test "bounds domain scanning work for adversarial maximum-size content" do
    valid = message(:llm, nil)
    adversarial = String.duplicate("a.", 8_192)

    task = Task.async(fn -> Validator.validate(%{valid | content: adversarial}) end)
    assert Task.await(task, 1_000) == {:error, :invalid_message}
  end

  test "redacts message content and identifiers from inspection" do
    message = %{
      message(:fallback, "123456789012345678")
      | conversation_id: "private-conversation",
        persona_id: "private-persona",
        content: "private generated content"
    }

    inspected = inspect(message)
    assert inspected =~ "origin: :fallback"

    for hidden <- ["private-conversation", "private-persona", "private generated", "123456"] do
      refute inspected =~ hidden
    end
  end

  defp message(origin, discord_message_id) do
    %Message{
      conversation_id: "conversation-1",
      persona_id: "observer",
      origin: origin,
      content: "The latest bounded fact is ready.",
      discord_message_id: discord_message_id,
      inserted_at: ~U[2026-08-05 12:00:00Z]
    }
  end
end

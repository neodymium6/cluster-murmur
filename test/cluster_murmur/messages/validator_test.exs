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

  test "classifies content with fixed non-content-bearing reasons" do
    assert Validator.classify_content("The latest bounded fact is ready.") == :ok

    for content <- ["", " \n ", "\u200B"] do
      assert Validator.classify_content(content) == {:error, :blank_content}
    end

    for content <- [123, <<255>>, String.duplicate("a", 16 * 1_024 + 1)] do
      assert Validator.classify_content(content) == {:error, :invalid_content}
    end

    for content <- ["https://example.invalid", "hello @everyone", "visit 192.0.2.10"] do
      assert Validator.classify_content(content) == {:error, :unsafe_content}
    end
  end

  test "distinguishes Japanese sentence full stops from Unicode domain separators" do
    for content <- [
          "今日は正常です。クラスタは静かです。",
          "処理が完了しました。次の実行を待ちます。",
          "異常はありません｡監視を続けます｡"
        ] do
      assert Validator.classify_content(content) == :ok
    end

    for content <- [
          "例え。テスト",
          "visit 例え。テスト",
          "visit 例え。テスト。",
          "今日は正常です。例え。テスト。",
          "visit 例え．テスト",
          "visit 例え｡テスト",
          "visit 192。0。2。10",
          "visit 例えです。テストます。",
          "例えです。テストます/pathです。",
          "参照先は例えです。テストます。",
          "リンク先は例えです。テストます。",
          "リンクは例えです。テストます。",
          "ドメインは例えです。テストます。",
          "サイトは例えです。テストます。",
          "アクセスは例えです。テストます。"
        ] do
      assert Validator.classify_content(content) == {:error, :unsafe_content}
    end
  end

  test "bounds domain scanning work for adversarial maximum-size content" do
    valid = message(:llm, nil)
    adversarial = String.duplicate("a.", 8_192)
    japanese_near_miss = String.duplicate("1だ。", 2_300) <> "1"

    task = Task.async(fn -> Validator.validate(%{valid | content: adversarial}) end)
    assert Task.await(task, 1_000) == {:error, :invalid_message}

    task = Task.async(fn -> Validator.classify_content(japanese_near_miss) end)
    assert Task.await(task, 1_000) == :ok
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

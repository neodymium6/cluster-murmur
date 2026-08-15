defmodule ClusterMurmur.Discord.PublicationPayloadTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.PublicationPayload
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Personas.Persona

  test "builds a fixed payload with mention parsing disabled" do
    assert {:ok, %PublicationPayload{} = payload} =
             PublicationPayload.build(message(), persona())

    assert payload.content == "A confirmed observation changed state."
    assert payload.username == "Observer"
    assert payload.avatar_url == nil
    assert payload.allowed_mentions == %{parse: []}
  end

  test "preserves one validated persona avatar override" do
    persona = persona(avatar: "https://example.com/avatar.png")

    assert {:ok, payload} = PublicationPayload.build(message(), persona)
    assert payload.avatar_url == "https://example.com/avatar.png"
  end

  test "preserves inert network and mention-looking content with parsing disabled" do
    for content <- [
          "Visit https://example.invalid",
          "Target 192.0.2.10 recovered.",
          "Hello @everyone and <@123>"
        ] do
      assert {:ok, payload} = PublicationPayload.build(message(content: content), persona())
      assert payload.content == content
      assert payload.allowed_mentions == %{parse: []}
    end
  end

  test "requires an exact unpublished runtime message" do
    valid = message()

    invalid = [
      nil,
      %{},
      %{valid | discord_message_id: "123"},
      %{valid | content: ""},
      %{valid | content: "hidden\tcontrol"},
      Map.put(valid, :private, true)
    ]

    for value <- invalid do
      assert PublicationPayload.build(value, persona()) ==
               {:error, :invalid_publication_payload}
    end
  end

  test "requires the exact enabled persona selected by the message" do
    valid = persona()

    invalid = [
      nil,
      %{},
      %{valid | id: "other"},
      %{valid | enabled: false},
      %{valid | display_name: ""},
      %{valid | avatar: "http://example.com/avatar.png"},
      Map.put(valid, :private, true)
    ]

    for value <- invalid do
      assert PublicationPayload.build(message(), value) ==
               {:error, :invalid_publication_payload}
    end
  end

  test "enforces Discord content character limits after byte validation" do
    exact = String.duplicate("😀", 2_000)
    too_long = exact <> "a"

    assert {:ok, payload} = PublicationPayload.build(message(content: exact), persona())
    assert String.length(payload.content) == 2_000

    assert PublicationPayload.build(message(content: too_long), persona()) ==
             {:error, :invalid_publication_payload}
  end

  test "enforces the Discord username character limit" do
    exact = String.duplicate("a", 80)
    too_long = exact <> "a"

    assert {:ok, payload} =
             PublicationPayload.build(message(), persona(display_name: exact))

    assert payload.username == exact

    assert PublicationPayload.build(message(), persona(display_name: too_long)) ==
             {:error, :invalid_publication_payload}
  end

  test "inspection and errors do not expose outbound content or identity" do
    assert {:ok, payload} =
             PublicationPayload.build(
               message(content: "Private but approved observation."),
               persona(display_name: "Private Persona")
             )

    inspected = inspect(payload)
    refute inspected =~ "Private"
    refute inspected =~ "approved observation"

    result = PublicationPayload.build(message(persona_id: "other"), persona())
    assert result == {:error, :invalid_publication_payload}
    refute inspect(result) =~ "other"
  end

  defp message(overrides \\ []) do
    struct!(
      Message,
      Keyword.merge(
        [
          conversation_id: "conversation-1",
          persona_id: "observer",
          origin: :llm,
          content: "A confirmed observation changed state.",
          discord_message_id: nil,
          inserted_at: ~U[2026-08-05 12:00:00.000000Z]
        ],
        overrides
      )
    )
  end

  defp persona(overrides \\ []) do
    struct!(
      Persona,
      Keyword.merge(
        [
          id: "observer",
          display_name: "Observer",
          avatar: nil,
          prompt: "Use only supplied facts.",
          enabled: true,
          interests: %{},
          behavior: %{},
          relationships: %{},
          metadata: %{}
        ],
        overrides
      )
    )
  end
end

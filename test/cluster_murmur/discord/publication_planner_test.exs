defmodule ClusterMurmur.Discord.PublicationPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{PublicationPlanner, WebhookSettings}
  alias ClusterMurmur.Discord.PublicationPlanner.Plan
  alias ClusterMurmur.Persistence.MessageRecord
  alias ClusterMurmur.Personas.Persona

  test "plans one exact unpublished durable message" do
    assert {:ok, %Plan{} = plan} =
             PublicationPlanner.plan(loaded(), persona(), settings())

    assert plan.record.id == 1
    assert plan.payload.content == "A bounded confirmed fact."
    assert plan.payload.username == "Observer"
    assert plan.payload.allowed_mentions == %{parse: []}
    assert plan.settings == settings()
  end

  test "skips a known published record without requiring current settings" do
    published = loaded(discord_message_id: "12345")

    assert PublicationPlanner.plan(published, nil, nil) == {:skip, :already_published}
  end

  test "rejects malformed loaded records before planning" do
    valid = loaded()

    for record <- [nil, %MessageRecord{}, %{valid | id: 0}, Map.put(valid, :private, true)] do
      assert PublicationPlanner.plan(record, persona(), settings()) ==
               {:error, :invalid_message_record}
    end
  end

  test "requires exact validated webhook settings for unpublished records" do
    invalid = [
      nil,
      %WebhookSettings{url: "https://example.invalid"},
      Map.put(settings(), :private, true)
    ]

    for value <- invalid do
      assert PublicationPlanner.plan(loaded(), persona(), value) ==
               {:error, :invalid_webhook_settings}
    end
  end

  test "requires the enabled persona correlated with the durable message" do
    for value <- [nil, %{persona() | id: "other"}, %{persona() | enabled: false}] do
      assert PublicationPlanner.plan(loaded(), value, settings()) ==
               {:error, :invalid_publication_payload}
    end
  end

  test "plans fallback and LLM origins through the same payload boundary" do
    for origin <- [:llm, :fallback] do
      assert {:ok, %Plan{record: %MessageRecord{origin: ^origin}}} =
               PublicationPlanner.plan(loaded(origin: origin), persona(), settings())
    end
  end

  test "plan inspection exposes neither content, identity, nor webhook credential" do
    assert {:ok, plan} =
             PublicationPlanner.plan(
               loaded(content: "Private approved fact."),
               persona(display_name: "Private Persona"),
               settings()
             )

    inspected = inspect(plan)

    for hidden <- ["Private", "approved fact", "fake-token", "discord"] do
      refute inspected =~ hidden
    end
  end

  defp loaded(overrides \\ []) do
    struct!(
      MessageRecord,
      Keyword.merge(
        [
          __meta__: Ecto.put_meta(%MessageRecord{}, state: :loaded).__meta__,
          id: 1,
          conversation_id: "conversation-1",
          persona_id: "observer",
          origin: :llm,
          content: "A bounded confirmed fact.",
          discord_message_id: nil,
          inserted_at: ~U[2026-08-05 12:01:00.000000Z]
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

  defp settings do
    %WebhookSettings{url: webhook_url()}
  end

  defp webhook_url do
    Enum.join(["https://", "discord", ".", "com", "/api/webhooks/1/fake-token"])
  end
end

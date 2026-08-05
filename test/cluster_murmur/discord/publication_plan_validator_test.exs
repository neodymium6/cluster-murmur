defmodule ClusterMurmur.Discord.PublicationPlanValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{PublicationPlanValidator, PublicationPlanner, WebhookSettings}
  alias ClusterMurmur.Persistence.MessageRecord
  alias ClusterMurmur.Personas.Persona

  test "accepts one exact planner-produced publication plan" do
    assert {:ok, plan} = PublicationPlanner.plan(loaded(), persona(), settings())
    assert PublicationPlanValidator.validate(plan, loaded(), persona(), settings()) == :ok
  end

  test "rejects altered plan fields and nested values" do
    assert {:ok, plan} = PublicationPlanner.plan(loaded(), persona(), settings())

    invalid = [
      nil,
      Map.put(plan, :private, true),
      %{plan | record: %{plan.record | content: "altered"}},
      %{plan | record: %{plan.record | discord_message_id: "12345"}},
      %{plan | persona: %{plan.persona | display_name: "Altered"}},
      %{plan | settings: %WebhookSettings{url: "https://example.invalid"}},
      %{plan | payload: %{plan.payload | content: "altered"}},
      %{plan | payload: %{plan.payload | allowed_mentions: %{parse: ["everyone"]}}}
    ]

    for value <- invalid do
      assert PublicationPlanValidator.validate(value, loaded(), persona(), settings()) ==
               {:error, :invalid_publication_plan}
    end
  end

  test "rejects a stale plan after the current durable record is published" do
    assert {:ok, plan} = PublicationPlanner.plan(loaded(), persona(), settings())

    assert PublicationPlanValidator.validate(
             plan,
             loaded(discord_message_id: "12345"),
             persona(),
             settings()
           ) == {:error, :invalid_publication_plan}
  end

  test "rejects correlated mutations against independent current inputs" do
    assert {:ok, plan} = PublicationPlanner.plan(loaded(), persona(), settings())
    changed_content = "Correlated altered content."

    forged_content = %{
      plan
      | record: %{plan.record | content: changed_content},
        payload: %{plan.payload | content: changed_content}
    }

    forged_persona = %{
      plan
      | record: %{plan.record | persona_id: "other"},
        persona: %{plan.persona | id: "other", display_name: "Other"},
        payload: %{plan.payload | username: "Other"}
    }

    for forged <- [forged_content, forged_persona] do
      assert PublicationPlanValidator.validate(forged, loaded(), persona(), settings()) ==
               {:error, :invalid_publication_plan}
    end
  end

  test "keeps validation errors and plans fully redacted" do
    assert {:ok, plan} =
             PublicationPlanner.plan(
               loaded(content: "Private approved fact."),
               persona(display_name: "Private Persona"),
               settings()
             )

    result =
      PublicationPlanValidator.validate(%{plan | payload: nil}, loaded(), persona(), settings())

    for inspected <- [inspect(plan), inspect(result)] do
      refute inspected =~ "Private"
      refute inspected =~ "fake-token"
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

  defp settings, do: %WebhookSettings{url: webhook_url()}

  defp webhook_url,
    do: Enum.join(["https://", "discord", ".", "com", "/api/webhooks/1/fake-token"])
end

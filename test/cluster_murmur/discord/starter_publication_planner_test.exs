defmodule ClusterMurmur.Discord.StarterPublicationPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{StarterPublicationPlanner, WebhookSettings}
  alias ClusterMurmur.Discord.StarterPublicationPlanner.Plan
  alias ClusterMurmur.TestSupport.RuntimeFixture

  test "plans one exact fixed publication from a persisted starter" do
    configuration = RuntimeFixture.configuration()
    persisted = RuntimeFixture.persisted(configuration)
    settings = RuntimeFixture.webhook_settings()

    assert {:ok, %Plan{} = plan} =
             StarterPublicationPlanner.plan(persisted, configuration, %{}, settings)

    assert plan.persisted === persisted
    assert plan.publication.record === persisted.message

    assert plan.publication.persona ===
             configuration.personas.personas[persisted.message.persona_id]

    assert plan.publication.settings === settings
    assert plan.publication.payload.content == persisted.message.content
    assert plan.publication.payload.username == "Caretaker"
    assert plan.publication.payload.avatar_url == nil
    assert plan.publication.payload.allowed_mentions == %{parse: []}
    assert StarterPublicationPlanner.validate(plan, configuration, %{}, settings) == :ok

    inspected = inspect(plan)
    refute inspected =~ persisted.message.content
    refute inspected =~ "Caretaker"
    refute inspected =~ "fake-token"
  end

  test "rejects forged persistence and changed configured persona identity" do
    configuration = RuntimeFixture.configuration()
    persisted = RuntimeFixture.persisted(configuration)
    settings = RuntimeFixture.webhook_settings()

    changed =
      put_in(
        configuration.personas.personas["caretaker"].display_name,
        "Changed Caretaker"
      )

    assert ClusterMurmur.Config.Configuration.validate(changed) == :ok

    for {candidate, candidate_configuration} <- [
          {nil, configuration},
          {Map.put(persisted, :private, true), configuration},
          {%{persisted | message: %{persisted.message | persona_id: "other"}}, configuration},
          {persisted, changed}
        ] do
      assert StarterPublicationPlanner.plan(candidate, candidate_configuration, %{}, settings) ==
               {:error, :invalid_starter_publication}
    end
  end

  test "requires exact current webhook settings" do
    configuration = RuntimeFixture.configuration()
    persisted = RuntimeFixture.persisted(configuration)

    for settings <- [
          nil,
          %WebhookSettings{url: "https://example.invalid"},
          Map.put(RuntimeFixture.webhook_settings(), :private, true)
        ] do
      assert StarterPublicationPlanner.plan(persisted, configuration, %{}, settings) ==
               {:error, :invalid_starter_publication}
    end
  end

  test "revalidates exact plan, current inputs, and payload correlation" do
    configuration = RuntimeFixture.configuration()
    persisted = RuntimeFixture.persisted(configuration)
    settings = RuntimeFixture.webhook_settings()

    assert {:ok, plan} =
             StarterPublicationPlanner.plan(persisted, configuration, %{}, settings)

    for forged <- [
          nil,
          Map.put(plan, :private, true),
          %{
            plan
            | persisted: %{persisted | conversation: %{persisted.conversation | turn_count: 2}}
          },
          %{
            plan
            | publication: %{
                plan.publication
                | payload: %{plan.publication.payload | allowed_mentions: %{parse: ["everyone"]}}
              }
          },
          %{
            plan
            | publication: %{plan.publication | record: %{persisted.message | content: "Other"}}
          }
        ] do
      assert StarterPublicationPlanner.validate(forged, configuration, %{}, settings) ==
               {:error, :invalid_starter_publication}
    end

    changed_settings = %WebhookSettings{
      url: Enum.join(["https://", "discord", ".com/api/webhooks/2/other-fake-token"])
    }

    assert StarterPublicationPlanner.validate(plan, configuration, %{}, changed_settings) ==
             {:error, :invalid_starter_publication}
  end
end

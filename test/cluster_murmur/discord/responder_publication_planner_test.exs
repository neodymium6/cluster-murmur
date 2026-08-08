defmodule ClusterMurmur.Discord.ResponderPublicationPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Personas
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer.Delivery
  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.Plan, as: ResponderPlan
  alias ClusterMurmur.Discord.ResponderPublicationPlanner
  alias ClusterMurmur.Persistence.{ConversationRecord, MessageRecord}
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @inserted_at ~U[2026-08-07 02:00:04.000000Z]

  test "builds one fixed publication plan from an exact persisted responder delivery" do
    {delivery, configuration, cooldowns, settings} = fixture()

    assert {:ok, %ResponderPublicationPlanner.Plan{} = plan} =
             ResponderPublicationPlanner.plan(
               delivery,
               configuration,
               cooldowns,
               settings
             )

    assert plan.delivery === delivery
    assert plan.publication.record === delivery.message
    assert plan.publication.persona.id == "responder"
    assert plan.publication.payload.content == "A factual response."
    assert plan.publication.payload.username == "Responder"

    assert ResponderPublicationPlanner.validate(
             plan,
             configuration,
             cooldowns,
             settings
           ) == :ok

    refute inspect(plan) =~ "A factual response."
    refute inspect(plan) =~ "fake-token"
  end

  test "rejects stale current inputs and forged delivery correlations" do
    {delivery, configuration, cooldowns, settings} = fixture()
    responder = configuration.personas.personas["responder"]
    changed_responder = %{responder | display_name: "Changed"}

    changed_configuration = %{
      configuration
      | personas: %Personas{
          personas: Map.put(configuration.personas.personas, "responder", changed_responder)
        }
    }

    invalid = [
      {Map.put(delivery, :unexpected, true), configuration, cooldowns, settings},
      {%{delivery | message: %{delivery.message | persona_id: "caretaker"}}, configuration,
       cooldowns, settings},
      {delivery, changed_configuration, cooldowns, settings},
      {delivery, configuration, %{}, settings},
      {delivery, configuration, cooldowns, %{settings | url: "https://example.com"}}
    ]

    for {rejected, current_configuration, current_cooldowns, current_settings} <- invalid do
      assert ResponderPublicationPlanner.plan(
               rejected,
               current_configuration,
               current_cooldowns,
               current_settings
             ) == {:error, :invalid_responder_publication}
    end
  end

  test "rejects forged lifecycle and responder eligibility plans" do
    {delivery, configuration, cooldowns, settings} = fixture()
    waiting = delivery.plan.input.continuation.conversation

    waiting_plan = %{delivery.plan | conversation: waiting}

    waiting_delivery = %{
      delivery
      | plan: waiting_plan,
        conversation: %{waiting | turn_count: waiting.turn_count + 1}
    }

    caretaker = configuration.personas.personas["caretaker"]
    ineligible_plan = %{delivery.plan | responder: caretaker}

    ineligible_delivery = %{
      delivery
      | plan: ineligible_plan,
        message: %{delivery.message | persona_id: caretaker.id}
    }

    for forged <- [waiting_delivery, ineligible_delivery] do
      assert ResponderContinuationConsumer.validate_delivery(forged, forged.plan) ==
               {:error, :invalid_responder_delivery}

      assert ResponderPublicationPlanner.plan(
               forged,
               configuration,
               cooldowns,
               settings
             ) == {:error, :invalid_responder_publication}
    end
  end

  test "rejects a modified fixed publication plan" do
    {delivery, configuration, cooldowns, settings} = fixture()

    assert {:ok, plan} =
             ResponderPublicationPlanner.plan(
               delivery,
               configuration,
               cooldowns,
               settings
             )

    forged = put_in(plan.publication.payload.content, "Altered content.")

    assert ResponderPublicationPlanner.validate(
             forged,
             configuration,
             cooldowns,
             settings
           ) == {:error, :invalid_responder_publication}
  end

  defp fixture do
    input = RuntimeFixture.responder_input()
    configuration = input.configuration
    waiting = input.continuation.conversation

    plan = %ResponderPlan{
      input: input,
      binding: configuration.bindings.bindings["characters"],
      outcome: :reply,
      responder: configuration.personas.personas["responder"],
      conversation: %{
        waiting
        | status: :generating,
          llm_call_count: waiting.llm_call_count + 1
      },
      planned_at: input.planned_at
    }

    message =
      %MessageRecord{
        id: 2,
        conversation_id: plan.conversation.id,
        persona_id: plan.responder.id,
        origin: :llm,
        content: "A factual response.",
        discord_message_id: nil,
        inserted_at: @inserted_at
      }
      |> Ecto.put_meta(state: :loaded)

    conversation = %ConversationRecord{
      plan.conversation
      | turn_count: plan.conversation.turn_count + 1
    }

    delivery = %Delivery{plan: plan, message: message, conversation: conversation}
    :ok = ResponderContinuationConsumer.validate_delivery(delivery, plan)

    {delivery, configuration, input.current_cooldowns, input.webhook_settings}
  end
end

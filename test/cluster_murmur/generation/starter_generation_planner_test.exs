defmodule ClusterMurmur.Generation.StarterGenerationPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Configuration, EventGroups, LLM, Routing, StateTracking, Triggers}
  alias ClusterMurmur.Config.Bindings, as: BindingCatalog
  alias ClusterMurmur.Config.Personas, as: PersonaCatalog
  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Generation.{PromptAssembler, StarterGenerationPlanner}
  alias ClusterMurmur.Generation.StarterGenerationPlanner.Plan
  alias ClusterMurmur.Persistence.{ConversationRecord, TriggerExecution}
  alias ClusterMurmur.Personas.{Binding, Persona}

  alias ClusterMurmur.Triggers.{
    EventTrigger,
    EventTriggerAuthorizer,
    EventTriggerConversationPlanner,
    EventTriggerConversationStarter,
    EventTriggerExecutionPlanner
  }

  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization
  alias ClusterMurmur.Triggers.EventTriggerConversationStarter.Started

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  test "plans one exact redacted first-turn generation request" do
    configuration = configuration()
    started = started(configuration)

    assert {:ok, %Plan{} = plan} =
             StarterGenerationPlanner.plan(started, configuration, %{})

    assert plan.started === started
    assert plan.context.persona.display_name == "Caretaker"
    assert plan.context.persona.instructions == "Use only supplied facts."
    assert plan.context.facts.event_type == "observation.failed"
    assert plan.context.facts.subject == "example-target"
    assert plan.context.facts.details == %{"detail" => "private fact"}
    assert plan.context.creative_context.conversation_kind == "operations"
    assert plan.context.creative_context.mood == "attentive"
    assert plan.context.conversation == []
    assert {:ok, plan.request} == PromptAssembler.assemble(plan.context)
    assert StarterGenerationPlanner.validate(plan, configuration, %{}) == :ok

    inspected = inspect(plan)
    refute inspected =~ "private fact"
    refute inspected =~ "Use only supplied facts"
    refute inspected =~ "example-target"
  end

  test "uses the configured binding group instead of untrusted event framing" do
    configuration = configuration()
    started = started(configuration, event(group: "valid event group but not a portable id"))

    assert {:ok, plan} = StarterGenerationPlanner.plan(started, configuration, %{})
    assert plan.context.creative_context.conversation_kind == "operations"
    assert plan.context.facts.group == "valid event group but not a portable id"
  end

  test "rejects forged or stale start capabilities before prompt assembly" do
    configuration = configuration()
    valid = started(configuration)

    for rejected <- [
          nil,
          Map.put(valid, :private, true),
          %{valid | execution: %{valid.execution | status: :started}},
          %{valid | conversation: %{valid.conversation | root_event_id: "other-event"}},
          %{valid | plan: %{valid.plan | starter: %{valid.plan.starter | prompt: "Forged"}}}
        ] do
      assert StarterGenerationPlanner.plan(rejected, configuration, %{}) ==
               {:error, :invalid_starter_generation}
    end
  end

  test "revalidates deterministic context and request correlation" do
    configuration = configuration()
    assert {:ok, plan} = StarterGenerationPlanner.plan(started(configuration), configuration, %{})

    for forged <- [
          nil,
          Map.put(plan, :private, true),
          %{
            plan
            | context: %{
                plan.context
                | creative_context: %{plan.context.creative_context | mood: "different"}
              }
          },
          %{plan | request: %{plan.request | conversation: [%{"speaker" => "private"}]}}
        ] do
      assert StarterGenerationPlanner.validate(forged, configuration, %{}) ==
               {:error, :invalid_starter_generation}
    end
  end

  defp started(configuration, event \\ event()) do
    trigger = configuration.triggers.triggers["failure-conversation"]

    assert {:ok, execution_plan} =
             EventTriggerExecutionPlanner.plan(trigger, event, nil, @executed_at)

    started_execution =
      %TriggerExecution{
        trigger_id: trigger.id,
        event_id: event.id,
        status: :started,
        executed_at: execution_plan.executed_at,
        cooldown_until: execution_plan.cooldown_until,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    authorization = %Authorization{plan: execution_plan, execution: started_execution}
    assert EventTriggerAuthorizer.validate(authorization) == :ok

    assert {:ok, conversation_plan} =
             EventTriggerConversationPlanner.plan(
               authorization,
               configuration,
               %{},
               "conversation-1",
               ClusterMurmur.Test.FirstWeightedRandom
             )

    conversation =
      %ConversationRecord{
        id: conversation_plan.conversation.id,
        root_event_id: event.id,
        status: :starting,
        turn_count: 0,
        llm_call_count: 0,
        started_at: @executed_at,
        completed_at: nil
      }
      |> Ecto.put_meta(state: :loaded)

    result = %Started{
      plan: conversation_plan,
      conversation: conversation,
      execution: %{started_execution | status: :completed}
    }

    assert EventTriggerConversationStarter.validate(result, configuration, %{}) == :ok
    result
  end

  defp configuration do
    persona = %Persona{
      id: "caretaker",
      display_name: "Caretaker",
      avatar: nil,
      prompt: "Use only supplied facts.",
      enabled: true,
      interests: %{"operations" => 2},
      behavior: %{
        "spontaneous_weight" => 1,
        "reply_weight" => 1,
        "cooldown_ms" => 60_000
      },
      relationships: %{},
      metadata: %{}
    }

    binding = %Binding{
      id: "characters",
      group: "operations",
      candidates: [%{persona: persona.id, weight: 1}]
    }

    trigger = %EventTrigger{
      id: "failure-conversation",
      matcher: %Matcher{
        predicates: [
          %Predicate{field: "type", operator: :equals, value: "observation.failed"}
        ]
      },
      action: :start_conversation,
      binding: binding.id,
      cooldown_ms: 60_000
    }

    %Configuration{
      version: 1,
      event_groups: %EventGroups{
        groups: %{"operations" => %{id: "operations", reply_probability: 0}}
      },
      personas: %PersonaCatalog{personas: %{persona.id => persona}},
      bindings: %BindingCatalog{bindings: %{binding.id => binding}},
      triggers: %Triggers{triggers: %{trigger.id => trigger}},
      routing: %Routing{webhook_secret_file_env: "DISCORD_WEBHOOK_SECRET_FILE"},
      llm: %LLM{
        provider: :openai_compatible,
        base_url_env: "LLM_BASE_URL",
        model_env: "LLM_MODEL",
        api_key_file_env: "LLM_API_KEY_FILE",
        timeout_ms: 20_000,
        max_output_tokens: 300
      },
      state_tracking: StateTracking.default()
    }
  end

  defp event(overrides \\ []) do
    struct!(
      Event,
      Keyword.merge(
        [
          id: "example-event",
          type: "observation.failed",
          source: "example-observer",
          subject: "example-target",
          group: "operations",
          severity: "warning",
          previous: "healthy",
          current: "failed",
          occurred_at: ~U[2026-08-07 01:59:59.000000Z],
          facts: %{"detail" => "private fact"}
        ],
        overrides
      )
    )
  end
end

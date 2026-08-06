defmodule ClusterMurmur.Triggers.EventTriggerConversationPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Configuration, EventGroups, LLM, Routing, StateTracking, Triggers}
  alias ClusterMurmur.Config.Bindings, as: BindingCatalog
  alias ClusterMurmur.Config.Personas, as: PersonaCatalog
  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Persistence.{PersonaCooldownRecord, TriggerExecution}
  alias ClusterMurmur.Personas.{Binding, Persona}

  alias ClusterMurmur.Triggers.{
    EventTrigger,
    EventTriggerAuthorizer,
    EventTriggerConversationPlanner
  }

  alias ClusterMurmur.Triggers.EventTriggerConversationPlanner.Plan

  @executed_at ~U[2026-08-06 22:30:00.000000Z]

  defmodule FakeExecutionStore do
    def start(plan) do
      execution = %ClusterMurmur.Persistence.TriggerExecution{
        trigger_id: plan.trigger.id,
        event_id: plan.event.id,
        status: :started,
        executed_at: plan.executed_at,
        cooldown_until: plan.cooldown_until,
        error_class: nil
      }

      {:ok, Ecto.put_meta(execution, state: :loaded)}
    end
  end

  defmodule ChoiceRandom do
    def weighted_choice(candidates) do
      Process.put({__MODULE__, :candidates}, candidates)
      {:ok, "caretaker"}
    end
  end

  defmodule RaisingRandom do
    def weighted_choice(_candidates), do: raise("private random diagnostic")
  end

  setup do
    Process.delete({ChoiceRandom, :candidates})
    :ok
  end

  test "plans one redacted pristine conversation with a configured eligible starter" do
    configuration = configuration()
    authorization = authorization(configuration)

    assert {:ok, %Plan{} = plan} =
             EventTriggerConversationPlanner.plan(
               authorization,
               configuration,
               %{},
               "conversation-1",
               ChoiceRandom
             )

    assert plan.authorization === authorization
    assert plan.binding === configuration.bindings.bindings["characters"]
    assert plan.starter === configuration.personas.personas["caretaker"]

    assert plan.conversation.id == "conversation-1"
    assert plan.conversation.root_event_id == authorization.plan.event.id
    assert plan.conversation.status == :starting
    assert plan.conversation.started_at == @executed_at
    assert plan.conversation.last_message_at == nil
    assert plan.conversation.turn_count == 0
    assert plan.conversation.llm_call_count == 0
    assert plan.conversation.participants == []
    assert plan.conversation.messages == []

    assert Process.get({ChoiceRandom, :candidates}) == [
             {"caretaker", 4},
             {"observer", 2}
           ]

    assert EventTriggerConversationPlanner.validate_plan(plan, configuration, %{}) == :ok

    inspected = inspect(plan)
    refute inspected =~ "private prompt"
    refute inspected =~ "conversation-1"
    refute inspected =~ "example-event"
    refute inspected =~ "caretaker"
    refute inspected =~ "2026"
  end

  test "returns no-starter without sampling empty or zero-positive projections" do
    configuration =
      configuration(
        personas: %{
          "observer" => persona("observer", enabled: false),
          "caretaker" => persona("caretaker", interest: 0, spontaneous: 0)
        },
        candidates: [
          %{persona: "observer", weight: 1},
          %{persona: "caretaker", weight: 0}
        ]
      )

    assert EventTriggerConversationPlanner.plan(
             authorization(configuration),
             configuration,
             %{},
             "conversation-1",
             RaisingRandom
           ) == {:skip, :no_starter}

    active_cooldown = cooldown("observer", ~U[2026-08-06 22:31:00.000000Z])

    one_candidate =
      configuration(
        personas: %{"observer" => persona("observer")},
        candidates: [%{persona: "observer", weight: 1}]
      )

    assert EventTriggerConversationPlanner.plan(
             authorization(one_candidate),
             one_candidate,
             %{"observer" => active_cooldown},
             "conversation-2",
             RaisingRandom
           ) == {:skip, :no_starter}
  end

  test "fails closed before selection for invalid authorization, configuration, and conversation" do
    configuration = configuration()
    authorization = authorization(configuration)

    assert EventTriggerConversationPlanner.plan(
             nil,
             configuration,
             %{},
             "conversation-1",
             RaisingRandom
           ) == {:error, :invalid_authorization}

    assert EventTriggerConversationPlanner.plan(
             authorization,
             %{configuration | version: 2},
             %{},
             "conversation-1",
             RaisingRandom
           ) == {:error, :invalid_configuration}

    mismatched_trigger = %{authorization.plan.trigger | cooldown_ms: 1}

    mismatched_configuration =
      put_in(
        configuration.triggers.triggers[authorization.plan.trigger.id],
        mismatched_trigger
      )

    assert Configuration.validate(mismatched_configuration) == :ok

    assert EventTriggerConversationPlanner.plan(
             authorization,
             mismatched_configuration,
             %{},
             "conversation-1",
             RaisingRandom
           ) == {:error, :invalid_authorization}

    assert EventTriggerConversationPlanner.plan(
             authorization,
             configuration,
             %{},
             "invalid conversation id",
             RaisingRandom
           ) == {:error, :invalid_conversation}
  end

  test "contains invalid cooldown projections and random failures" do
    configuration = configuration()
    authorization = authorization(configuration)

    invalid_cooldown = %PersonaCooldownRecord{
      persona_id: "observer",
      last_spoken_at: @executed_at,
      cooldown_until: @executed_at
    }

    assert EventTriggerConversationPlanner.plan(
             authorization,
             configuration,
             %{"observer" => invalid_cooldown},
             "conversation-1",
             ChoiceRandom
           ) == {:error, :invalid_starter_projection}

    result =
      EventTriggerConversationPlanner.plan(
        authorization,
        configuration,
        %{},
        "conversation-1",
        RaisingRandom
      )

    assert result == {:error, :invalid_starter_selection}
    refute inspect(result) =~ "private"
  end

  test "revalidates exact plan correlation and current starter eligibility" do
    configuration = configuration()
    authorization = authorization(configuration)

    assert {:ok, plan} =
             EventTriggerConversationPlanner.plan(
               authorization,
               configuration,
               %{},
               "conversation-1",
               ChoiceRandom
             )

    active_cooldown = cooldown("caretaker", ~U[2026-08-06 22:31:00.000000Z])

    for forged <- [
          nil,
          Map.put(plan, :private, true),
          %{plan | binding: %{plan.binding | id: "other-binding"}},
          %{plan | starter: %{plan.starter | display_name: "Different"}},
          %{plan | conversation: %{plan.conversation | root_event_id: "other-event"}},
          %{plan | conversation: %{plan.conversation | participants: [plan.starter.id]}},
          %{plan | authorization: %{plan.authorization | execution: %TriggerExecution{}}}
        ] do
      assert EventTriggerConversationPlanner.validate_plan(forged, configuration, %{}) ==
               {:error, :invalid_conversation_plan}
    end

    assert EventTriggerConversationPlanner.validate_plan(
             plan,
             configuration,
             %{"caretaker" => active_cooldown}
           ) == {:error, :invalid_conversation_plan}
  end

  defp authorization(configuration) do
    trigger = configuration.triggers.triggers["failure-conversation"]

    assert {:ok, authorization} =
             EventTriggerAuthorizer.authorize(
               trigger,
               event(),
               @executed_at,
               FakeExecutionStore
             )

    authorization
  end

  defp configuration(options \\ []) do
    trigger = trigger()

    personas =
      Keyword.get(options, :personas, %{
        "observer" => persona("observer", interest: 1),
        "caretaker" => persona("caretaker", interest: 2, spontaneous: 1)
      })

    candidates =
      Keyword.get(options, :candidates, [
        %{persona: "observer", weight: 1},
        %{persona: "caretaker", weight: 1}
      ])

    %Configuration{
      version: 1,
      event_groups: %EventGroups{
        groups: %{"operations" => %{id: "operations", reply_probability: 0.5}}
      },
      personas: %PersonaCatalog{personas: personas},
      bindings: %BindingCatalog{
        bindings: %{
          "characters" => %Binding{
            id: "characters",
            group: "operations",
            candidates: candidates
          }
        }
      },
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

  defp persona(id, options \\ []) do
    %Persona{
      id: id,
      display_name: String.capitalize(id),
      avatar: nil,
      prompt: "private prompt for #{id}",
      enabled: Keyword.get(options, :enabled, true),
      interests: %{"operations" => Keyword.get(options, :interest, 0)},
      behavior: %{
        "spontaneous_weight" => Keyword.get(options, :spontaneous, 0),
        "reply_weight" => 0,
        "cooldown_ms" => 60_000
      },
      relationships: %{},
      metadata: %{}
    }
  end

  defp trigger do
    %EventTrigger{
      id: "failure-conversation",
      matcher: %Matcher{
        predicates: [
          %Predicate{field: "type", operator: :equals, value: "observation.failed"}
        ]
      },
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: 60_000
    }
  end

  defp event do
    %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      group: "operations",
      severity: "warning",
      occurred_at: ~U[2026-08-06 22:29:59.000000Z],
      facts: %{"detail" => "private"}
    }
  end

  defp cooldown(persona_id, cooldown_until) do
    %PersonaCooldownRecord{
      persona_id: persona_id,
      last_spoken_at: @executed_at,
      cooldown_until: cooldown_until
    }
    |> Ecto.put_meta(state: :loaded)
  end
end

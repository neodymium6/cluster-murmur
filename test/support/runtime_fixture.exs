defmodule ClusterMurmur.TestSupport.RuntimeFixture do
  @moduledoc false

  alias ClusterMurmur.Config.{Configuration, EventGroups, LLM, Routing, StateTracking, Triggers}
  alias ClusterMurmur.Config.Bindings, as: BindingCatalog
  alias ClusterMurmur.Config.Personas, as: PersonaCatalog
  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Discord.WebhookSettings

  alias ClusterMurmur.Generation.{
    ProviderSettings,
    StarterGenerationPlanner,
    StarterGenerator,
    StarterMessagePersister
  }

  alias ClusterMurmur.Generation.StarterMessagePersister.Persisted
  alias ClusterMurmur.Persistence.{ConversationRecord, MessageRecord, TriggerExecution}
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

  def configuration do
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

  def event(overrides \\ []) do
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

  def started(configuration \\ configuration(), event \\ event()) do
    trigger = configuration.triggers.triggers["failure-conversation"]
    {:ok, execution_plan} = EventTriggerExecutionPlanner.plan(trigger, event, nil, @executed_at)

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
    :ok = EventTriggerAuthorizer.validate(authorization)

    {:ok, conversation_plan} =
      EventTriggerConversationPlanner.plan(
        authorization,
        configuration,
        %{},
        "conversation-1",
        __MODULE__.FirstRandom
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

    :ok = EventTriggerConversationStarter.validate(result, configuration, %{})
    result
  end

  def generation_plan(configuration \\ configuration(), event \\ event()) do
    {:ok, plan} = StarterGenerationPlanner.plan(started(configuration, event), configuration, %{})
    plan
  end

  def provider_settings do
    %ProviderSettings{
      provider: :openai_compatible,
      base_url: "https://llm.example.invalid/v1",
      model: "example-model",
      api_key: "clearly-fake-api-key",
      timeout_ms: 20_000,
      max_output_tokens: 300
    }
  end

  def webhook_settings do
    %WebhookSettings{url: Enum.join(["https://", "discord", ".com/api/webhooks/1/fake-token"])}
  end

  def generated(configuration \\ configuration(), event \\ event()) do
    {:ok, generated} =
      StarterGenerator.generate(
        generation_plan(configuration, event),
        configuration,
        %{},
        provider_settings(),
        ~U[2026-08-07 02:00:01.000000Z],
        __MODULE__.FakeProvider,
        fn :request -> {:ok, "A bounded fact."} end
      )

    generated
  end

  def persisted(configuration \\ configuration(), event \\ event()) do
    generated = generated(configuration, event)
    original = generated.plan.started.conversation

    message =
      %MessageRecord{
        id: 1,
        conversation_id: generated.message.conversation_id,
        persona_id: generated.message.persona_id,
        origin: generated.message.origin,
        content: generated.message.content,
        discord_message_id: nil,
        inserted_at: generated.message.inserted_at
      }
      |> Ecto.put_meta(state: :loaded)

    conversation = %ConversationRecord{
      original
      | turn_count: original.turn_count + 1,
        llm_call_count: original.llm_call_count + 1
    }

    result = %Persisted{generated: generated, message: message, conversation: conversation}
    :ok = StarterMessagePersister.validate(result, configuration, %{})
    result
  end

  defmodule FakeProvider do
    @moduledoc false
    def generate(_request, _settings, transport), do: transport.(:request)
  end

  defmodule FirstRandom do
    @moduledoc false
    def weighted_choice([{id, _weight} | _rest]), do: {:ok, id}
  end
end

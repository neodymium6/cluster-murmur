defmodule ClusterMurmur.TestSupport.RuntimeFixture do
  @moduledoc false

  alias ClusterMurmur.Config.{Configuration, EventGroups, LLM, Routing, StateTracking, Triggers}
  alias ClusterMurmur.Config.Bindings, as: BindingCatalog
  alias ClusterMurmur.Config.Personas, as: PersonaCatalog
  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Discord.WebhookSettings

  alias ClusterMurmur.Discord.{
    StarterPublicationExecutor,
    StarterPublicationPlanner
  }

  alias ClusterMurmur.Discord.StarterPublicationExecutor.Outcome
  alias ClusterMurmur.Discord.StarterPublicationStarter.Started, as: PublicationStarted

  alias ClusterMurmur.Conversations.{
    Budget,
    Conversation,
    StarterReplyFinisher
  }

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.Input,
    as: ResponderContinuationInput

  alias ClusterMurmur.Generation.{
    ProviderSettings,
    StarterGenerationPlanner,
    StarterGenerator,
    StarterMessagePersister
  }

  alias ClusterMurmur.Generation.StarterMessagePersister.Persisted
  alias ClusterMurmur.Messages.Message

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    MessageRecord,
    PersonaCooldownRecord,
    PublicationAttemptRecord,
    TriggerExecution
  }

  alias ClusterMurmur.Personas.{Binding, Persona, ResponderPolicy}
  alias ClusterMurmur.Personas.StarterCooldownRecorder.Recorded

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

  def recorded(configuration \\ configuration(), event \\ event()) do
    persisted = persisted(configuration, event)
    settings = webhook_settings()
    {:ok, plan} = StarterPublicationPlanner.plan(persisted, configuration, %{}, settings)

    started_attempt =
      %PublicationAttemptRecord{
        message_id: persisted.message.id,
        status: :started,
        started_at: ~U[2026-08-07 02:00:02.000000Z],
        completed_at: nil,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    attempt = %{
      started_attempt
      | status: :succeeded,
        completed_at: ~U[2026-08-07 02:00:03.000000Z],
        error_class: nil
    }

    published = %Outcome{
      started: %PublicationStarted{plan: plan, attempt: started_attempt},
      attempt: attempt,
      message: %{persisted.message | discord_message_id: "12345"},
      status: :succeeded,
      error_class: nil
    }

    :ok = StarterPublicationExecutor.validate(published, configuration, %{}, settings)

    cooldown =
      %PersonaCooldownRecord{
        persona_id: persisted.message.persona_id,
        last_spoken_at: attempt.completed_at,
        cooldown_until: ~U[2026-08-07 02:01:03.000000Z]
      }
      |> Ecto.put_meta(state: :loaded)

    %Recorded{published: published, cooldown: cooldown}
  end

  def responder_configuration do
    configuration = configuration()
    caretaker = configuration.personas.personas["caretaker"]

    responder = %{
      caretaker
      | id: "responder",
        display_name: "Responder",
        prompt: "Reply using only supplied facts and conversation history.",
        behavior: %{"reply_weight" => 2, "cooldown_ms" => 60_000}
    }

    binding = configuration.bindings.bindings["characters"]
    binding = %{binding | candidates: binding.candidates ++ [%{persona: responder.id, weight: 1}]}

    configuration
    |> put_in(
      [Access.key(:event_groups), Access.key(:groups), "operations", :reply_probability],
      1
    )
    |> Map.put(:personas, %PersonaCatalog{
      personas: %{caretaker.id => caretaker, responder.id => responder}
    })
    |> Map.put(:bindings, %BindingCatalog{bindings: %{binding.id => binding}})
  end

  def responder_input(configuration \\ responder_configuration()) do
    recorded = recorded(configuration)
    settings = webhook_settings()

    {:continue, :reply, continuation} =
      StarterReplyFinisher.finish(
        recorded,
        configuration,
        %{},
        settings,
        __MODULE__.EndpointRandom,
        __MODULE__.ResponderConversationStore
      )

    %ResponderContinuationInput{
      continuation: continuation,
      configuration: configuration,
      starter_cooldowns: %{},
      current_cooldowns: %{recorded.cooldown.persona_id => recorded.cooldown},
      webhook_settings: settings,
      conversation: responder_conversation(continuation, recorded),
      budget: %Budget{
        max_turns: 3,
        max_participants: 2,
        max_duration_ms: 300_000,
        max_llm_calls: 3
      },
      planned_at: ~U[2026-08-07 02:00:03.000000Z],
      policy: %ResponderPolicy{
        allow_same_persona_consecutively: false,
        allow_persona_reentry: false
      },
      no_reply_weight: 1
    }
  end

  defp responder_conversation(continuation, recorded) do
    waiting = continuation.conversation
    published = recorded.published.message

    message = %Message{
      conversation_id: published.conversation_id,
      persona_id: published.persona_id,
      origin: published.origin,
      content: published.content,
      discord_message_id: published.discord_message_id,
      inserted_at: published.inserted_at
    }

    %Conversation{
      id: waiting.id,
      root_event_id: waiting.root_event_id,
      status: waiting.status,
      started_at: waiting.started_at,
      last_message_at: message.inserted_at,
      turn_count: waiting.turn_count,
      llm_call_count: waiting.llm_call_count,
      participants: [message.persona_id],
      messages: [message]
    }
  end

  defmodule FakeProvider do
    @moduledoc false
    def generate(_request, _settings, transport), do: transport.(:request)
  end

  defmodule FirstRandom do
    @moduledoc false
    def weighted_choice([{id, _weight} | _rest]), do: {:ok, id}
  end

  defmodule EndpointRandom do
    @moduledoc false
    def uniform, do: raise("endpoint probability must not sample")
  end

  defmodule ResponderRandom do
    @moduledoc false
    def weighted_choice(_choices), do: {:ok, {:reply, "responder"}}
  end

  defmodule ResponderConversationStore do
    @moduledoc false
    def wait(conversation), do: {:ok, %{conversation | status: :waiting}}

    def complete(conversation, completed_at),
      do: {:ok, %{conversation | status: :completed, completed_at: completed_at}}
  end
end

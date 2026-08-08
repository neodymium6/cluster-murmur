defmodule ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Triggers
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult
  alias ClusterMurmur.Persistence.{EventDispatchCandidate, TriggerExecution}
  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn
  alias ClusterMurmur.Runtime.ResponderTurnCycle.Adapters, as: ResponderAdapters
  alias ClusterMurmur.TestSupport.RuntimeFixture

  alias ClusterMurmur.Triggers.{
    AuthorizedConversationPipelineConsumer,
    EventConversationIdentity,
    EventDispatchPlanner,
    EventTriggerAuthorizer,
    EventTriggerExecutionPlanner,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.{Adapters, Input}
  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.{Context, Entry}
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.Adapters, as: StarterAdapters
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.Input, as: StarterInput
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  defmodule AdaptersStub do
    def consume(_plan), do: :unused
    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def append_reserved(_conversation, _message), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused
    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def complete(_conversation_id, _completed_at), do: :unused
    def wait(_conversation), do: :unused
    def claim_generation(_conversation, _persona_id), do: :unused
    def consume_generation(_conversation, _persona_id), do: :unused
    def confirm_completed(_conversation), do: :unused

    def weighted_choice(_choices) do
      send(self(), :random_called)
      :unused
    end

    def uniform, do: :unused
  end

  test "preflights the complete authorization-free conversation batch" do
    configuration = RuntimeFixture.responder_configuration()
    event = RuntimeFixture.event()
    poll_result = poll_result([event])
    plan = plan(poll_result, configuration)
    trigger = configuration.triggers.triggers["failure-conversation"]
    context = context([entry(input(configuration, "conversation-1"), event, trigger)])

    assert AuthorizedConversationPipelineConsumer.preflight(
             plan,
             poll_result,
             configuration,
             context
           ) == :ok

    refute inspect(context) =~ "clearly-fake-api-key"
    refute inspect(context) =~ "fake-token"
    refute inspect(context) =~ "conversation-1"
  end

  test "preflights bounded conversations for a durable dispatch plan" do
    configuration = RuntimeFixture.responder_configuration()
    event = RuntimeFixture.event()
    plan = dispatch_plan(event, configuration)
    trigger = configuration.triggers.triggers["failure-conversation"]
    context = context([entry(input(configuration, "conversation-1"), event, trigger)])

    assert AuthorizedConversationPipelineConsumer.preflight(plan, configuration, context) == :ok

    changed = configuration_with_two_triggers()

    assert AuthorizedConversationPipelineConsumer.preflight(plan, changed, context) ==
             {:error, :invalid_conversation_context}
  end

  test "rejects malformed batches before the dispatcher can authorize" do
    configuration = configuration_with_two_triggers()
    event = RuntimeFixture.event()
    poll_result = poll_result([event])
    plan = plan(poll_result, configuration)
    first_trigger = configuration.triggers.triggers["failure-conversation"]
    second_trigger = configuration.triggers.triggers["second-failure-conversation"]

    first = entry(input(configuration, "conversation-1"), event, first_trigger)
    second = entry(input(configuration, "conversation-2"), event, second_trigger)
    authorization = RuntimeFixture.started().plan.authorization

    invalid_contexts = [
      context([first]),
      context([first, put_in(second.input.starter.authorization, authorization)]),
      context([
        first,
        put_in(second.input.starter.conversation_id, first.input.starter.conversation_id)
      ]),
      context([
        first,
        put_in(second.input.starter.generated_at, ~U[2026-08-07 01:59:58.000000Z])
      ]),
      context([first, put_in(second.input.responder_turns, [])]),
      context([first, %{second | trigger: first.trigger}]),
      Map.put(context([first, second]), :private, true)
    ]

    for invalid <- invalid_contexts do
      assert AuthorizedConversationPipelineConsumer.preflight(
               plan,
               poll_result,
               configuration,
               invalid
             ) == {:error, :invalid_conversation_context}
    end
  end

  test "rejects invalid positions without executing an adapter" do
    configuration = RuntimeFixture.responder_configuration()
    event = RuntimeFixture.event()
    poll_result = poll_result([event])
    plan = plan(poll_result, configuration)
    trigger = configuration.triggers.triggers["failure-conversation"]
    context = context([entry(input(configuration, "conversation-1"), event, trigger)])
    authorization = RuntimeFixture.started(configuration, event).plan.authorization

    assert AuthorizedConversationPipelineConsumer.preflight(
             plan,
             poll_result,
             configuration,
             context
           ) == :ok

    assert AuthorizedConversationPipelineConsumer.consume(authorization, 1, context) ==
             {:error, :conversation_failed}

    assert AuthorizedConversationPipelineConsumer.consume(authorization, 256, context) ==
             {:error, :conversation_failed}
  end

  test "rejects swapped cross-index authorizations before invoking the pipeline" do
    configuration = configuration_with_two_triggers()
    event = RuntimeFixture.event()
    first_trigger = configuration.triggers.triggers["failure-conversation"]
    second_trigger = configuration.triggers.triggers["second-failure-conversation"]

    context =
      context([
        entry(input(configuration, "conversation-1"), event, first_trigger),
        entry(input(configuration, "conversation-2"), event, second_trigger)
      ])

    first_authorization = authorization(first_trigger, event)
    second_authorization = authorization(second_trigger, event)

    assert AuthorizedConversationPipelineConsumer.consume(first_authorization, 1, context) ==
             {:error, :conversation_failed}

    assert AuthorizedConversationPipelineConsumer.consume(second_authorization, 0, context) ==
             {:error, :conversation_failed}

    [first_entry, _second_entry] = context.entries
    forged = %{context | entries: [Map.put(first_entry, :private, true)]}

    assert AuthorizedConversationPipelineConsumer.consume(first_authorization, 0, forged) ==
             {:error, :conversation_failed}

    refute_received :random_called
  end

  test "rejects input-only swaps for a durable multi-trigger plan" do
    configuration = configuration_with_two_triggers()
    event = RuntimeFixture.event()
    plan = dispatch_plan(event, configuration)
    first_trigger = configuration.triggers.triggers["failure-conversation"]
    second_trigger = configuration.triggers.triggers["second-failure-conversation"]

    first = entry(input(configuration, "conversation-1"), event, first_trigger)
    second = entry(input(configuration, "conversation-2"), event, second_trigger)
    swapped = context([%{first | input: second.input}, %{second | input: first.input}])

    assert AuthorizedConversationPipelineConsumer.preflight(plan, configuration, swapped) ==
             {:error, :invalid_conversation_context}

    first_authorization = authorization(first_trigger, event)

    assert AuthorizedConversationPipelineConsumer.consume(first_authorization, 0, swapped) ==
             {:error, :conversation_failed}
  end

  defp context(entries), do: %Context{entries: entries, adapters: adapters()}

  defp entry(input, event, trigger) do
    assert {:ok, conversation_id} =
             EventConversationIdentity.derive(event, trigger, @executed_at)

    %Entry{
      input: put_in(input.starter.conversation_id, conversation_id),
      event: event,
      trigger: trigger,
      executed_at: @executed_at
    }
  end

  defp input(configuration, conversation_id) do
    starter = %StarterInput{
      authorization: nil,
      configuration: configuration,
      cooldowns: %{},
      conversation_id: conversation_id,
      provider_settings: RuntimeFixture.provider_settings(),
      webhook_settings: RuntimeFixture.webhook_settings(),
      generated_at: ~U[2026-08-07 02:00:01.000000Z],
      publication_started_at: ~U[2026-08-07 02:00:02.000000Z],
      publication_completed_at: ~U[2026-08-07 02:00:03.000000Z],
      generation_transport: fn _request -> :unused end,
      publication_transport: fn _request -> :unused end
    }

    %Input{
      starter: starter,
      responder_turns: [
        %Turn{
          planned_at: ~U[2026-08-07 02:00:03.000000Z],
          generated_at: ~U[2026-08-07 02:00:04.000000Z],
          publication_started_at: ~U[2026-08-07 02:00:05.000000Z],
          publication_completed_at: ~U[2026-08-07 02:00:06.000000Z],
          generation_transport: fn _request -> :unused end,
          publication_transport: fn _request -> :unused end
        }
      ]
    }
  end

  defp adapters do
    %Adapters{
      starter: %StarterAdapters{
        conversation_action_store: AdaptersStub,
        provider: AdaptersStub,
        message_store: AdaptersStub,
        publication_start_store: AdaptersStub,
        publisher: AdaptersStub,
        publication_terminal_store: AdaptersStub,
        cooldown_store: AdaptersStub,
        conversation_store: AdaptersStub,
        starter_random: AdaptersStub,
        reply_random: AdaptersStub
      },
      responder: %ResponderAdapters{
        random: AdaptersStub,
        conversation_store: AdaptersStub,
        provider: AdaptersStub,
        message_store: AdaptersStub,
        publication_start_store: AdaptersStub,
        publisher: AdaptersStub,
        publication_terminal_store: AdaptersStub,
        cooldown_store: AdaptersStub
      }
    }
  end

  defp configuration_with_two_triggers do
    configuration = RuntimeFixture.responder_configuration()
    trigger = configuration.triggers.triggers["failure-conversation"]
    second = %{trigger | id: "second-failure-conversation"}

    %{
      configuration
      | triggers: %Triggers{triggers: %{trigger.id => trigger, second.id => second}}
    }
  end

  defp authorization(trigger, event) do
    {:ok, plan} = EventTriggerExecutionPlanner.plan(trigger, event, nil, @executed_at)

    execution =
      %TriggerExecution{
        trigger_id: trigger.id,
        event_id: event.id,
        status: :started,
        executed_at: plan.executed_at,
        cooldown_until: plan.cooldown_until,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    authorization = %Authorization{plan: plan, execution: execution}
    assert EventTriggerAuthorizer.validate(authorization) == :ok
    authorization
  end

  defp poll_result(events) do
    %PollResult{
      target_count: length(events),
      ingested_count: length(events),
      event_count: length(events),
      failure_count: 0,
      events: events,
      failures: []
    }
  end

  defp plan(poll_result, configuration) do
    {:ok, plan} = PollEventTriggerPlanner.plan(poll_result, configuration, @executed_at)
    plan
  end

  defp dispatch_plan(event, configuration) do
    candidate = %EventDispatchCandidate{event_id: event.id, enqueued_at: @executed_at}
    {:ok, plan} = EventDispatchPlanner.plan([candidate], [event], configuration, @executed_at)
    plan
  end
end

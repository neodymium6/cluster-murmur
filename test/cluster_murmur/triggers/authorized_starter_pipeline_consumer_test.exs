defmodule ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Triggers
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult
  alias ClusterMurmur.Persistence.EventDispatchCandidate
  alias ClusterMurmur.TestSupport.RuntimeFixture

  alias ClusterMurmur.Triggers.{
    AuthorizedStarterPipelineConsumer,
    EventConversationIdentity,
    EventDispatchPlanner,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, Input}
  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.{Context, Entry}

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  defmodule AdaptersStub do
    def consume(_plan), do: :unused
    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused
    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def complete(_conversation_id, _completed_at), do: :unused
    def wait(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused
  end

  test "preflights the complete authorization-free batch" do
    configuration = RuntimeFixture.configuration()
    event = RuntimeFixture.event()
    poll_result = poll_result([event])
    plan = plan(poll_result, configuration)
    trigger = configuration.triggers.triggers["failure-conversation"]
    context = context([entry(input(configuration, "conversation-1"), event, trigger)])

    assert AuthorizedStarterPipelineConsumer.preflight(
             plan,
             poll_result,
             configuration,
             context
           ) == :ok

    refute inspect(context) =~ "clearly-fake-api-key"
    refute inspect(context) =~ "fake-token"
    refute inspect(context) =~ "conversation-1"
  end

  test "preflights the same fixed inputs for a durable dispatch plan" do
    configuration = RuntimeFixture.configuration()
    event = RuntimeFixture.event()
    plan = dispatch_plan(event, configuration)
    trigger = configuration.triggers.triggers["failure-conversation"]
    context = context([entry(input(configuration, "conversation-1"), event, trigger)])

    assert AuthorizedStarterPipelineConsumer.preflight(plan, configuration, context) == :ok

    assert AuthorizedStarterPipelineConsumer.preflight(
             %{plan | match_count: 0},
             configuration,
             context
           ) == {:error, :invalid_starter_context}
  end

  test "rejects every malformed batch before a pipeline can run" do
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
      context([first, %{second | input: %{second.input | authorization: authorization}}]),
      context([
        first,
        %{second | input: %{second.input | conversation_id: first.input.conversation_id}}
      ]),
      context([
        first,
        %{second | input: %{second.input | generated_at: ~U[2026-08-07 01:59:58.000000Z]}}
      ]),
      context([first, %{second | trigger: first.trigger}]),
      Map.put(context([first, second]), :private, true)
    ]

    for invalid <- invalid_contexts do
      assert AuthorizedStarterPipelineConsumer.preflight(
               plan,
               poll_result,
               configuration,
               invalid
             ) == {:error, :invalid_starter_context}
    end
  end

  test "rejects invalid positions without executing an adapter" do
    configuration = RuntimeFixture.configuration()
    event = RuntimeFixture.event()
    poll_result = poll_result([event])
    plan = plan(poll_result, configuration)
    trigger = configuration.triggers.triggers["failure-conversation"]
    context = context([entry(input(configuration, "conversation-1"), event, trigger)])
    authorization = RuntimeFixture.started(configuration, event).plan.authorization

    assert AuthorizedStarterPipelineConsumer.preflight(
             plan,
             poll_result,
             configuration,
             context
           ) == :ok

    assert AuthorizedStarterPipelineConsumer.consume(authorization, 1, context) ==
             {:error, :starter_failed}

    assert AuthorizedStarterPipelineConsumer.consume(authorization, 256, context) ==
             {:error, :starter_failed}
  end

  test "rejects swapped durable trigger positions before invoking a pipeline" do
    configuration = configuration_with_two_triggers()
    event = RuntimeFixture.event()
    plan = dispatch_plan(event, configuration)
    first_trigger = configuration.triggers.triggers["failure-conversation"]
    second_trigger = configuration.triggers.triggers["second-failure-conversation"]

    first = entry(input(configuration, "conversation-1"), event, first_trigger)
    second = entry(input(configuration, "conversation-2"), event, second_trigger)
    swapped = context([%{first | trigger: second_trigger}, %{second | trigger: first_trigger}])
    swapped_inputs = context([%{first | input: second.input}, %{second | input: first.input}])

    assert AuthorizedStarterPipelineConsumer.preflight(plan, configuration, swapped) ==
             {:error, :invalid_starter_context}

    assert AuthorizedStarterPipelineConsumer.preflight(plan, configuration, swapped_inputs) ==
             {:error, :invalid_starter_context}

    first_authorization = RuntimeFixture.started(configuration, event).plan.authorization

    assert AuthorizedStarterPipelineConsumer.consume(first_authorization, 0, swapped_inputs) ==
             {:error, :starter_failed}

    valid = context([first, second])

    assert AuthorizedStarterPipelineConsumer.consume(first_authorization, 1, valid) ==
             {:error, :starter_failed}
  end

  defp context(entries) do
    %Context{entries: entries, adapters: adapters()}
  end

  defp entry(input, event, trigger) do
    assert {:ok, conversation_id} =
             EventConversationIdentity.derive(event, trigger, @executed_at)

    %Entry{
      input: %{input | conversation_id: conversation_id},
      event: event,
      trigger: trigger,
      executed_at: @executed_at
    }
  end

  defp input(configuration, conversation_id) do
    %Input{
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
  end

  defp adapters do
    %Adapters{
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
    }
  end

  defp configuration_with_two_triggers do
    configuration = RuntimeFixture.configuration()
    trigger = configuration.triggers.triggers["failure-conversation"]
    second = %{trigger | id: "second-failure-conversation"}

    %{
      configuration
      | triggers: %Triggers{triggers: %{trigger.id => trigger, second.id => second}}
    }
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

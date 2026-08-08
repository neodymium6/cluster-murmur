defmodule ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Triggers
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult
  alias ClusterMurmur.TestSupport.RuntimeFixture

  alias ClusterMurmur.Triggers.{AuthorizedStarterPipelineConsumer, PollEventTriggerPlanner}

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, Input}
  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Context

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
    context = context([input(configuration, "conversation-1")])

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

  test "rejects every malformed batch before a pipeline can run" do
    configuration = configuration_with_two_triggers()
    event = RuntimeFixture.event()
    poll_result = poll_result([event])
    plan = plan(poll_result, configuration)
    first = input(configuration, "conversation-1")
    second = input(configuration, "conversation-2")
    authorization = RuntimeFixture.started().plan.authorization

    invalid_contexts = [
      context([first]),
      context([first, %{second | authorization: authorization}]),
      context([first, %{second | conversation_id: first.conversation_id}]),
      context([first, %{second | generated_at: ~U[2026-08-07 01:59:58.000000Z]}]),
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
    context = context([input(configuration, "conversation-1")])
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

  defp context(inputs) do
    %Context{inputs: inputs, adapters: adapters()}
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
end

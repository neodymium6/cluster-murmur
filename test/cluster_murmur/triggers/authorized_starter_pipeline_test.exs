defmodule ClusterMurmur.Triggers.AuthorizedStarterPipelineTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Conversations.StarterReplyFinisher
  alias ClusterMurmur.Discord.{WebhookPublisher, WebhookRequest, WebhookResponse}

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationStore,
    EventStore,
    EventTriggerConversationActionStore,
    MessageRecord,
    MessageStore,
    PersonaCooldownStore,
    PublicationAttemptStore,
    TriggerExecution
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Observations.{IngestionPlanner, Observation}
  alias ClusterMurmur.Observers.Client
  alias ClusterMurmur.Runtime.PollStarterCycle
  alias ClusterMurmur.Runtime.PollStarterCycle.ConversationRuntime
  alias ClusterMurmur.Runtime.ResponderTurnSchedule
  alias ClusterMurmur.Runtime.ResponderTurnSchedule.Step
  alias ClusterMurmur.Runtime.ResponderTurnCycle.Adapters, as: ResponderAdapters

  alias ClusterMurmur.Repo.Migrations.{
    AddPublicationAttemptDispatching,
    CreateConversations,
    CreateEvents,
    CreateMessages,
    CreatePersonaCooldowns,
    CreatePublicationAttempts,
    CreateResponderGenerationClaims,
    CreateTriggerExecutions
  }

  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult

  alias ClusterMurmur.Triggers.{
    AuthorizedStarterPipeline,
    AuthorizedStarterPipelineConsumer,
    EventTriggerAuthorizer,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, Input}

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.Adapters,
    as: ConversationAdapters

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Context
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.SharedInput
  alias ClusterMurmur.Runtime.PollStarterCycle.Context, as: CycleContext

  @events_version 20_260_804_180_500
  @executions_version 20_260_804_200_000
  @conversations_version 20_260_805_200_000
  @messages_version 20_260_805_220_000
  @cooldowns_version 20_260_805_224_000
  @attempts_version 20_260_805_230_000
  @dispatching_version 20_260_805_231_000
  @responder_claims_version 20_260_808_060_000
  @executed_at ~U[2026-08-07 02:00:00.000000Z]
  @generated_at ~U[2026-08-07 02:00:01.000000Z]
  @publication_started_at ~U[2026-08-07 02:00:02.000000Z]
  @publication_completed_at ~U[2026-08-07 02:00:03.000000Z]

  defmodule FakeProvider do
    def generate(request, _settings, transport), do: transport.(request)
  end

  defmodule UnusedRandom do
    def weighted_choice(_choices), do: raise("single candidate must not sample")
    def uniform, do: raise("zero reply probability must not sample")
  end

  defmodule ConversationStarterRandom do
    def weighted_choice(_choices), do: {:ok, "caretaker"}
  end

  defmodule ConversationReplyRandom do
    def uniform, do: 0.0
  end

  defmodule ConversationResponderRandom do
    def weighted_choice(_choices), do: {:ok, {:reply, "responder"}}
  end

  defmodule CycleObserver do
    def list_targets(:process_dictionary), do: {:ok, [%{id: "example-target"}]}

    def observe_target(:process_dictionary, "example-target") do
      Process.get({__MODULE__, :observation})
    end
  end

  defmodule CycleIngestionStore do
    def ingest(observation, policy) do
      with {:ok, plan} <- IngestionPlanner.plan(nil, observation, policy),
           {:ok, _event} <- EventStore.insert(plan.event) do
        {:ok, plan}
      end
    end
  end

  setup_all do
    migrations = [
      {@events_version, CreateEvents},
      {@executions_version, CreateTriggerExecutions},
      {@conversations_version, CreateConversations},
      {@messages_version, CreateMessages},
      {@cooldowns_version, CreatePersonaCooldowns},
      {@attempts_version, CreatePublicationAttempts},
      {@dispatching_version, AddPublicationAttemptDispatching},
      {@responder_claims_version, CreateResponderGenerationClaims}
    ]

    for {version, migration} <- migrations do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- Enum.reverse(migrations) do
        Ecto.Migrator.down(Repo, version, migration,
          log: false,
          log_migrations_sql: false,
          log_migrator_sql: false
        )
      end
    end)

    :ok
  end

  setup do
    for table <- [
          "responder_generation_claims",
          "publication_attempts",
          "persona_cooldowns",
          "messages",
          "conversations",
          "trigger_executions",
          "events"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}", [], log: false)
    end

    :ok
  end

  test "runs one authorized event through fake generation and Discord into durable completion" do
    parent = self()

    generation_transport = fn request ->
      send(parent, {:generation, request})
      {:ok, "A bounded confirmed fact."}
    end

    publication_transport = fn request ->
      send(parent, {:publication, request})
      {:ok, %WebhookResponse{status: 200, body: ~s({"id":"12345"})}}
    end

    input = input(generation_transport, publication_transport)

    assert {:ok, completed} = AuthorizedStarterPipeline.run(input, adapters())

    assert StarterReplyFinisher.validate(
             completed,
             input.configuration,
             %{},
             input.webhook_settings
           ) == :ok

    assert_receive {:generation, _request}
    assert_receive {:publication, %WebhookRequest{}}
    refute_receive {:generation, _request}
    refute_receive {:publication, _request}

    conversation = Repo.get!(ConversationRecord, input.conversation_id)
    assert conversation.status == :completed
    assert conversation.turn_count == 1
    assert conversation.llm_call_count == 1
    assert conversation.completed_at == @publication_completed_at

    [message] = Repo.all(MessageRecord)
    assert message.content == "A bounded confirmed fact."
    assert message.discord_message_id == "12345"

    assert {:ok, attempt} = PublicationAttemptStore.fetch(message.id)
    assert attempt.status == :succeeded
    assert attempt.completed_at == @publication_completed_at

    assert {:ok, cooldown} = PersonaCooldownStore.fetch(message.persona_id)
    assert cooldown.last_spoken_at == @publication_completed_at
    assert cooldown.cooldown_until == ~U[2026-08-07 02:01:03.000000Z]

    assert %TriggerExecution{status: :completed} =
             Repo.get_by!(TriggerExecution,
               trigger_id: "failure-conversation",
               event_id: "example-event"
             )

    assert AuthorizedStarterPipeline.run(input, adapters()) ==
             {:error, :conversation_conflict}

    refute_receive {:generation, _request}
    refute_receive {:publication, _request}

    inspected = inspect(input) <> inspect(completed)
    refute inspected =~ "clearly-fake-api-key"
    refute inspected =~ "fake-token"
    refute inspected =~ message.content
  end

  test "rejects invalid late inputs before the first conversation mutation" do
    parent = self()

    generation_transport = fn _request ->
      send(parent, :generation_called)
      {:ok, "Must not run."}
    end

    publication_transport = fn _request ->
      send(parent, :publication_called)
      {:error, :outcome_unknown}
    end

    valid = input(generation_transport, publication_transport)

    for invalid <- [
          %{valid | publication_completed_at: @generated_at},
          %{valid | provider_settings: %{valid.provider_settings | timeout_ms: 1}},
          Map.put(valid, :private, true)
        ] do
      assert AuthorizedStarterPipeline.run(invalid, adapters()) ==
               {:error, :invalid_starter_pipeline}
    end

    assert Repo.aggregate(ConversationRecord, :count) == 0
    assert Repo.aggregate(MessageRecord, :count) == 0
    refute_receive :generation_called
    refute_receive :publication_called
  end

  test "consumes one preflighted poll authorization through the concrete pipeline" do
    parent = self()

    input =
      input(
        fn request ->
          send(parent, {:generation, request})
          {:ok, "A bounded confirmed fact."}
        end,
        fn request ->
          send(parent, {:publication, request})
          {:ok, %WebhookResponse{status: 200, body: ~s({"id":"12345"})}}
        end
      )

    event = input.authorization.plan.event

    poll_result = %PollResult{
      target_count: 1,
      ingested_count: 1,
      event_count: 1,
      failure_count: 0,
      events: [event],
      failures: []
    }

    assert {:ok, plan} =
             PollEventTriggerPlanner.plan(poll_result, input.configuration, @executed_at)

    context = %Context{inputs: [%{input | authorization: nil}], adapters: adapters()}

    assert AuthorizedStarterPipelineConsumer.preflight(
             plan,
             poll_result,
             input.configuration,
             context
           ) == :ok

    assert AuthorizedStarterPipelineConsumer.consume(input.authorization, 0, context) == :ok
    assert Repo.get!(ConversationRecord, input.conversation_id).status == :completed
    assert_receive {:generation, _request}
    assert_receive {:publication, %WebhookRequest{}}
    refute_receive {:generation, _request}
    refute_receive {:publication, _request}
  end

  test "runs a fake observer event through the complete SQLite-backed starter cycle" do
    parent = self()

    configuration =
      RuntimeFixture.configuration()
      |> Map.put(
        :state_tracking,
        %ClusterMurmur.Config.StateTracking{failures_required: 1, successes_required: 1}
      )

    Process.put(
      {CycleObserver, :observation},
      {:ok,
       %Observation{
         source: "example-observer",
         subject: "example-target",
         state: :unhealthy,
         observed_at: ~U[2026-08-07 01:59:59.000000Z],
         facts: %{"detail" => "private fact"},
         labels: %{"category" => "monitoring"}
       }}
    )

    assert {:ok, observer_client} = Client.new(CycleObserver, :process_dictionary)

    shared_input = %SharedInput{
      configuration: configuration,
      cooldowns: %{},
      provider_settings: RuntimeFixture.provider_settings(),
      webhook_settings: RuntimeFixture.webhook_settings(),
      generation_transport: fn request ->
        send(parent, {:generation, request})
        {:ok, "A bounded confirmed fact."}
      end,
      publication_transport: fn request ->
        send(parent, {:publication, request})
        {:ok, %WebhookResponse{status: 200, body: ~s({"id":"12345"})}}
      end
    }

    context = %CycleContext{shared_input: shared_input, adapters: adapters()}

    assert {:ok, result} =
             PollStarterCycle.run(
               observer_client,
               configuration,
               ~U[2026-08-07 01:00:00.000000Z],
               context,
               CycleIngestionStore
             )

    assert result.event_count == 1
    assert result.match_count == 1
    assert result.dispatched_count == 1
    assert result.dispatch_failure_count == 0

    [conversation] = Repo.all(ConversationRecord)
    assert conversation.status == :completed
    assert conversation.started_at == ~U[2026-08-07 01:59:59.000000Z]
    assert_receive {:generation, _request}
    assert_receive {:publication, %WebhookRequest{}}
    refute inspect(result) =~ "private fact"
  end

  test "runs a fake observer event through the opt-in bounded conversation cycle" do
    parent = self()

    configuration =
      RuntimeFixture.responder_configuration()
      |> Map.put(
        :state_tracking,
        %ClusterMurmur.Config.StateTracking{failures_required: 1, successes_required: 1}
      )

    Process.put(
      {CycleObserver, :observation},
      {:ok,
       %Observation{
         source: "example-observer",
         subject: "example-target",
         state: :unhealthy,
         observed_at: ~U[2026-08-07 01:59:59.000000Z],
         facts: %{"detail" => "private fact"},
         labels: %{"category" => "monitoring"}
       }}
    )

    assert {:ok, observer_client} = Client.new(CycleObserver, :process_dictionary)
    starter_adapters = conversation_starter_adapters()

    shared_input = %SharedInput{
      configuration: configuration,
      cooldowns: %{},
      provider_settings: RuntimeFixture.provider_settings(),
      webhook_settings: RuntimeFixture.webhook_settings(),
      generation_transport: fn request ->
        send(parent, {:generation, :starter, request})
        {:ok, "A confirmed starter fact."}
      end,
      publication_transport: fn request ->
        send(parent, {:publication, :starter, request})
        {:ok, %WebhookResponse{status: 200, body: ~s({"id":"12345"})}}
      end
    }

    context = %CycleContext{
      shared_input: shared_input,
      adapters: starter_adapters,
      conversation_runtime: %ConversationRuntime{
        schedule: conversation_schedule(parent),
        adapters: %ConversationAdapters{
          starter: starter_adapters,
          responder: conversation_responder_adapters()
        }
      }
    }

    assert {:ok, result} =
             PollStarterCycle.run(
               observer_client,
               configuration,
               ~U[2026-08-07 01:00:00.000000Z],
               context,
               CycleIngestionStore
             )

    assert result.event_count == 1
    assert result.dispatched_count == 1
    assert result.dispatch_failure_count == 0

    [conversation] = Repo.all(ConversationRecord)
    assert conversation.status == :completed
    assert conversation.turn_count == 2
    assert conversation.llm_call_count == 2
    assert conversation.completed_at == ~U[2026-08-07 02:00:03.000000Z]

    messages = Repo.all(MessageRecord) |> Enum.sort_by(& &1.id)
    assert Enum.map(messages, & &1.persona_id) == ["caretaker", "responder"]

    assert_receive {:generation, :starter, _request}
    assert_receive {:publication, :starter, %WebhookRequest{}}
    assert_receive {:generation, :responder, _request}
    assert_receive {:publication, :responder, %WebhookRequest{}}
    refute inspect(result) =~ "private fact"
  end

  defp input(generation_transport, publication_transport) do
    configuration = RuntimeFixture.configuration()
    event = RuntimeFixture.event()
    assert {:ok, _record} = EventStore.insert(event)

    trigger = configuration.triggers.triggers["failure-conversation"]
    assert {:ok, authorization} = EventTriggerAuthorizer.authorize(trigger, event, @executed_at)

    %Input{
      authorization: authorization,
      configuration: configuration,
      cooldowns: %{},
      conversation_id: "conversation-1",
      provider_settings: RuntimeFixture.provider_settings(),
      webhook_settings: RuntimeFixture.webhook_settings(),
      generated_at: @generated_at,
      publication_started_at: @publication_started_at,
      publication_completed_at: @publication_completed_at,
      generation_transport: generation_transport,
      publication_transport: publication_transport
    }
  end

  defp adapters do
    %Adapters{
      conversation_action_store: EventTriggerConversationActionStore,
      provider: FakeProvider,
      message_store: MessageStore,
      publication_start_store: PublicationAttemptStore,
      publisher: WebhookPublisher,
      publication_terminal_store: PublicationAttemptStore,
      cooldown_store: PersonaCooldownStore,
      conversation_store: ConversationStore,
      starter_random: UnusedRandom,
      reply_random: UnusedRandom
    }
  end

  defp conversation_starter_adapters do
    %Adapters{
      conversation_action_store: EventTriggerConversationActionStore,
      provider: FakeProvider,
      message_store: MessageStore,
      publication_start_store: PublicationAttemptStore,
      publisher: WebhookPublisher,
      publication_terminal_store: PublicationAttemptStore,
      cooldown_store: PersonaCooldownStore,
      conversation_store: ConversationStore,
      starter_random: ConversationStarterRandom,
      reply_random: ConversationReplyRandom
    }
  end

  defp conversation_responder_adapters do
    %ResponderAdapters{
      random: ConversationResponderRandom,
      conversation_store: ConversationStore,
      provider: FakeProvider,
      message_store: MessageStore,
      publication_start_store: PublicationAttemptStore,
      publisher: WebhookPublisher,
      publication_terminal_store: PublicationAttemptStore,
      cooldown_store: PersonaCooldownStore
    }
  end

  defp conversation_schedule(parent) do
    %ResponderTurnSchedule{
      steps: [
        %Step{
          planned_after_ms: 0,
          generated_after_ms: 1_000,
          publication_started_after_ms: 2_000,
          publication_completed_after_ms: 3_000,
          generation_transport: fn request ->
            send(parent, {:generation, :responder, request})
            {:ok, "A confirmed responder fact."}
          end,
          publication_transport: fn request ->
            send(parent, {:publication, :responder, request})
            {:ok, %WebhookResponse{status: 200, body: ~s({"id":"23456"})}}
          end
        },
        %Step{
          planned_after_ms: 4_000,
          generated_after_ms: 5_000,
          publication_started_after_ms: 6_000,
          publication_completed_after_ms: 7_000,
          generation_transport: fn _request -> :unused end,
          publication_transport: fn _request -> :unused end
        }
      ]
    }
  end
end

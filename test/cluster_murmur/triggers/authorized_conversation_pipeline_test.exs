defmodule ClusterMurmur.Triggers.AuthorizedConversationPipelineTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner
  alias ClusterMurmur.Discord.{WebhookPublisher, WebhookRequest, WebhookResponse}

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationStore,
    EventStore,
    EventTriggerConversationActionStore,
    MessageRecord,
    MessageStore,
    PersonaCooldownStore,
    PublicationAttemptStore
  }

  alias ClusterMurmur.Repo

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

  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn
  alias ClusterMurmur.Runtime.ResponderTurnCycle.Adapters, as: ResponderAdapters
  alias ClusterMurmur.TestSupport.RuntimeFixture

  alias ClusterMurmur.Triggers.{
    AuthorizedConversationPipeline,
    EventTriggerAuthorizer
  }

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.{Adapters, Input}
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.Adapters, as: StarterAdapters
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.Input, as: StarterInput

  @events_version 20_260_804_180_500
  @executions_version 20_260_804_200_000
  @conversations_version 20_260_805_200_000
  @messages_version 20_260_805_220_000
  @cooldowns_version 20_260_805_224_000
  @attempts_version 20_260_805_230_000
  @dispatching_version 20_260_805_231_000
  @responder_claims_version 20_260_808_060_000
  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  defmodule FakeProvider do
    def generate(request, _settings, transport), do: transport.(request)
  end

  defmodule DivergentProvider do
    def generate(request, _settings, transport), do: transport.(request)
  end

  defmodule StarterRandom do
    def weighted_choice(choices) do
      send(self(), {:starter_choices, choices})
      {:ok, "caretaker"}
    end
  end

  defmodule ReplyRandom do
    def uniform, do: 0.0
  end

  defmodule ResponderRandom do
    def weighted_choice(choices) do
      [outcome | remaining] = Process.get({__MODULE__, :outcomes}, [])
      Process.put({__MODULE__, :outcomes}, remaining)
      send(self(), {:responder_choices, choices})
      {:ok, outcome}
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

    Process.put({ResponderRandom, :outcomes}, [{:reply, "responder"}])
    :ok
  end

  test "runs a proven starter continuation through bounded responder completion" do
    parent = self()

    starter_generation = fn request ->
      send(parent, {:generation, :starter, request})
      {:ok, "A confirmed starter fact."}
    end

    starter_publication = fn request ->
      send(parent, {:publication, :starter, request})
      {:ok, %WebhookResponse{status: 200, body: ~s({"id":"12345"})}}
    end

    input = input(starter_generation, starter_publication)

    assert {:ok, :no_reply, %ResponderContinuationPlanner.Result{} = terminal} =
             AuthorizedConversationPipeline.run(input, adapters())

    assert terminal.outcome == :no_reply
    assert terminal.status == :dispatched

    conversation = Repo.get!(ConversationRecord, input.starter.conversation_id)
    assert conversation.status == :completed
    assert conversation.turn_count == 2
    assert conversation.llm_call_count == 2
    assert conversation.completed_at == ~U[2026-08-07 02:00:07.000000Z]

    messages = Repo.all(MessageRecord) |> Enum.sort_by(& &1.id)

    assert Enum.map(messages, &{&1.persona_id, &1.content}) == [
             {"caretaker", "A confirmed starter fact."},
             {"responder", "A confirmed responder fact."}
           ]

    assert_receive {:starter_choices, _choices}
    assert_receive {:generation, :starter, _request}
    assert_receive {:publication, :starter, %WebhookRequest{}}
    assert_receive {:responder_choices, _choices}
    assert_receive {:generation, :responder, _request}
    assert_receive {:publication, :responder, %WebhookRequest{}}
    refute_receive {:generation, _turn, _request}
    refute_receive {:publication, _turn, _request}
    assert Process.get({ResponderRandom, :outcomes}) == []

    inspected = inspect({input, terminal})
    refute inspected =~ "clearly-fake-api-key"
    refute inspected =~ "fake-token"
    refute inspected =~ "confirmed"
  end

  test "rejects a malformed later turn or divergent shared adapter before starter effects" do
    parent = self()

    input =
      input(
        fn _request ->
          send(parent, :generation_called)
          {:ok, "Must not run."}
        end,
        fn _request ->
          send(parent, :publication_called)
          {:error, :outcome_unknown}
        end
      )

    [first, second] = input.responder_turns
    invalid_turns = [first, %{second | generated_at: second.planned_at |> DateTime.add(-1)}]

    assert AuthorizedConversationPipeline.run(
             %{input | responder_turns: invalid_turns},
             adapters()
           ) ==
             {:error, :invalid_authorized_conversation_pipeline}

    divergent = adapters()

    divergent = %{
      divergent
      | responder: %{divergent.responder | provider: DivergentProvider}
    }

    assert AuthorizedConversationPipeline.run(input, divergent) ==
             {:error, :invalid_authorized_conversation_pipeline}

    assert Repo.aggregate(ConversationRecord, :count) == 0
    assert Repo.aggregate(MessageRecord, :count) == 0
    refute_received :generation_called
    refute_received :publication_called
  end

  defp input(generation_transport, publication_transport) do
    configuration = RuntimeFixture.responder_configuration()
    event = RuntimeFixture.event()
    assert {:ok, _record} = EventStore.insert(event)
    trigger = configuration.triggers.triggers["failure-conversation"]
    assert {:ok, authorization} = EventTriggerAuthorizer.authorize(trigger, event, @executed_at)

    starter = %StarterInput{
      authorization: authorization,
      configuration: configuration,
      cooldowns: %{},
      conversation_id: "conversation-1",
      provider_settings: RuntimeFixture.provider_settings(),
      webhook_settings: RuntimeFixture.webhook_settings(),
      generated_at: ~U[2026-08-07 02:00:01.000000Z],
      publication_started_at: ~U[2026-08-07 02:00:02.000000Z],
      publication_completed_at: ~U[2026-08-07 02:00:03.000000Z],
      generation_transport: generation_transport,
      publication_transport: publication_transport
    }

    %Input{starter: starter, responder_turns: responder_turns()}
  end

  defp responder_turns do
    [
      %Turn{
        planned_at: ~U[2026-08-07 02:00:03.000000Z],
        generated_at: ~U[2026-08-07 02:00:04.000000Z],
        publication_started_at: ~U[2026-08-07 02:00:05.000000Z],
        publication_completed_at: ~U[2026-08-07 02:00:06.000000Z],
        generation_transport: fn request ->
          send(self(), {:generation, :responder, request})
          {:ok, "A confirmed responder fact."}
        end,
        publication_transport: fn request ->
          send(self(), {:publication, :responder, request})
          {:ok, %WebhookResponse{status: 200, body: ~s({"id":"23456"})}}
        end
      },
      %Turn{
        planned_at: ~U[2026-08-07 02:00:07.000000Z],
        generated_at: ~U[2026-08-07 02:00:08.000000Z],
        publication_started_at: ~U[2026-08-07 02:00:09.000000Z],
        publication_completed_at: ~U[2026-08-07 02:00:10.000000Z],
        generation_transport: fn _request -> :unused end,
        publication_transport: fn _request -> :unused end
      }
    ]
  end

  defp adapters do
    %Adapters{
      starter: %StarterAdapters{
        conversation_action_store: EventTriggerConversationActionStore,
        provider: FakeProvider,
        message_store: MessageStore,
        publication_start_store: PublicationAttemptStore,
        publisher: WebhookPublisher,
        publication_terminal_store: PublicationAttemptStore,
        cooldown_store: PersonaCooldownStore,
        conversation_store: ConversationStore,
        starter_random: StarterRandom,
        reply_random: ReplyRandom
      },
      responder: %ResponderAdapters{
        random: ResponderRandom,
        conversation_store: ConversationStore,
        provider: FakeProvider,
        message_store: MessageStore,
        publication_start_store: PublicationAttemptStore,
        publisher: WebhookPublisher,
        publication_terminal_store: PublicationAttemptStore,
        cooldown_store: PersonaCooldownStore
      }
    }
  end
end

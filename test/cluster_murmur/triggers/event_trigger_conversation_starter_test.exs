defmodule ClusterMurmur.Triggers.EventTriggerConversationStarterTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.{Configuration, EventGroups, LLM, Routing, StateTracking, Triggers}
  alias ClusterMurmur.Config.Bindings, as: BindingCatalog
  alias ClusterMurmur.Config.Personas, as: PersonaCatalog
  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    EventStore,
    TriggerExecution,
    TriggerExecutionStore
  }

  alias ClusterMurmur.Personas.{Binding, Persona}
  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddIncompleteConversationIndex,
    CreateConversations,
    CreateEvents,
    CreateTriggerExecutions
  }

  alias ClusterMurmur.Triggers.{
    EventTrigger,
    EventTriggerAuthorizer,
    EventTriggerConversationPlanner,
    EventTriggerConversationStarter
  }

  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization
  alias ClusterMurmur.Triggers.EventTriggerConversationStarter.Started
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan, as: ExecutionPlan

  @executed_at ~U[2026-08-07 01:00:00.000000Z]
  @events_version 20_260_804_180_500
  @executions_version 20_260_804_200_000
  @conversations_version 20_260_805_200_000
  @incomplete_index_version 20_260_805_210_000

  defmodule FakeStore do
    def consume(plan) do
      conversation = plan.conversation
      Process.put({__MODULE__, :plan}, plan)

      {:ok,
       {
         %ConversationRecord{
           id: conversation.id,
           root_event_id: conversation.root_event_id,
           status: :starting,
           turn_count: 0,
           llm_call_count: 0,
           started_at: conversation.started_at,
           completed_at: nil
         }
         |> Ecto.put_meta(state: :loaded),
         %{plan.authorization.execution | status: :completed}
       }}
    end
  end

  defmodule ConflictingStore do
    def consume(_plan), do: {:error, :conversation_conflict}
  end

  defmodule MalformedStore do
    def consume(plan) do
      {:ok, {%ConversationRecord{}, %{plan.authorization.execution | status: :completed}}}
    end
  end

  defmodule InvalidExecutionStore do
    def consume(plan) do
      conversation = plan.conversation

      record =
        %ConversationRecord{
          id: conversation.id,
          root_event_id: conversation.root_event_id,
          status: :starting,
          turn_count: 0,
          llm_call_count: 0,
          started_at: conversation.started_at,
          completed_at: nil
        }
        |> Ecto.put_meta(state: :loaded)

      {:ok, {record, plan.authorization.execution}}
    end
  end

  defmodule RaisingStore do
    def consume(_plan), do: raise("private storage diagnostic")
  end

  setup_all do
    for {version, migration} <- [
          {@events_version, CreateEvents},
          {@executions_version, CreateTriggerExecutions},
          {@conversations_version, CreateConversations},
          {@incomplete_index_version, AddIncompleteConversationIndex}
        ] do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- [
            {@incomplete_index_version, AddIncompleteConversationIndex},
            {@conversations_version, CreateConversations},
            {@executions_version, CreateTriggerExecutions},
            {@events_version, CreateEvents}
          ] do
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
    Process.delete({FakeStore, :plan})
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM conversations", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM trigger_executions", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "starts one exact authorized conversation and returns a redacted capability" do
    configuration = configuration()
    plan = conversation_plan(configuration)

    assert {:ok, %Started{} = started} =
             EventTriggerConversationStarter.start(plan, configuration, %{}, FakeStore)

    assert Process.get({FakeStore, :plan}) === plan
    assert started.plan === plan
    assert started.conversation.id == plan.conversation.id
    assert started.conversation.root_event_id == plan.conversation.root_event_id
    assert started.conversation.status == :starting
    assert started.execution.status == :completed
    assert EventTriggerConversationStarter.validate(started, configuration, %{}) == :ok

    inspected = inspect(started)
    refute inspected =~ "conversation-1"
    refute inspected =~ "example-event"
    refute inspected =~ "caretaker"
  end

  test "rejects forged plans before calling the store" do
    configuration = configuration()
    plan = conversation_plan(configuration)
    forged = %{plan | starter: %{plan.starter | display_name: "Forged"}}

    assert EventTriggerConversationStarter.start(forged, configuration, %{}, FakeStore) ==
             {:error, :invalid_conversation_plan}

    assert Process.get({FakeStore, :plan}) == nil
  end

  test "preserves stable store conflicts and contains store failures" do
    configuration = configuration()
    plan = conversation_plan(configuration)

    assert EventTriggerConversationStarter.start(
             plan,
             configuration,
             %{},
             ConflictingStore
           ) == {:error, :conversation_conflict}

    assert EventTriggerConversationStarter.start(plan, configuration, %{}, MalformedStore) ==
             {:error, :invalid_conversation_record}

    assert EventTriggerConversationStarter.start(
             plan,
             configuration,
             %{},
             InvalidExecutionStore
           ) == {:error, :invalid_execution}

    result = EventTriggerConversationStarter.start(plan, configuration, %{}, RaisingStore)
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  test "rejects malformed dependencies without raising or retaining values" do
    configuration = configuration()
    plan = conversation_plan(configuration)

    for {forged_plan, forged_configuration, cooldowns, store} <- [
          {nil, configuration, %{}, FakeStore},
          {plan, nil, %{}, FakeStore},
          {plan, configuration, %{}, String},
          {plan, configuration, %{private: true}, FakeStore}
        ] do
      assert {:error, _reason} =
               EventTriggerConversationStarter.start(
                 forged_plan,
                 forged_configuration,
                 cooldowns,
                 store
               )
    end
  end

  test "revalidates exact capability and record correlation" do
    configuration = configuration()
    plan = conversation_plan(configuration)

    assert {:ok, started} =
             EventTriggerConversationStarter.start(plan, configuration, %{}, FakeStore)

    for forged <- [
          nil,
          Map.put(started, :private, true),
          %{started | plan: %{plan | conversation: %{plan.conversation | id: "other"}}},
          %{started | conversation: %{started.conversation | root_event_id: "other-event"}},
          %{started | conversation: %{started.conversation | status: :waiting}},
          %{started | execution: %{started.execution | status: :started}}
        ] do
      assert EventTriggerConversationStarter.validate(forged, configuration, %{}) ==
               {:error, :invalid_conversation_plan}
    end
  end

  test "atomically consumes one durable authorization at most once" do
    configuration = configuration()
    plan = persisted_conversation_plan(configuration, "conversation-1")

    assert {:ok, started} = EventTriggerConversationStarter.start(plan, configuration, %{})
    assert started.execution.status == :completed
    assert Repo.aggregate(ConversationRecord, :count) == 1

    assert EventTriggerConversationStarter.start(plan, configuration, %{}) ==
             {:error, :conversation_conflict}

    assert Repo.aggregate(ConversationRecord, :count) == 1
  end

  test "rolls back a different conversation ID when the authorization was consumed" do
    configuration = configuration()
    original = persisted_conversation_plan(configuration, "conversation-1")

    assert {:ok, _started} =
             EventTriggerConversationStarter.start(original, configuration, %{})

    assert {:ok, reused} =
             EventTriggerConversationPlanner.plan(
               original.authorization,
               configuration,
               %{},
               "conversation-2",
               ClusterMurmur.Test.FirstWeightedRandom
             )

    assert EventTriggerConversationStarter.start(reused, configuration, %{}) ==
             {:error, :execution_conflict}

    assert Repo.aggregate(ConversationRecord, :count) == 1
    assert Repo.get(ConversationRecord, "conversation-2") == nil
  end

  test "rejects an authorization completed before conversation persistence" do
    configuration = configuration()
    plan = persisted_conversation_plan(configuration, "conversation-1")
    assert {:ok, _completed} = TriggerExecutionStore.complete(plan.authorization.execution)

    assert EventTriggerConversationStarter.start(plan, configuration, %{}) ==
             {:error, :execution_conflict}

    assert Repo.aggregate(ConversationRecord, :count) == 0
  end

  defp conversation_plan(configuration) do
    authorization = authorization(configuration)

    assert {:ok, plan} =
             EventTriggerConversationPlanner.plan(
               authorization,
               configuration,
               %{},
               "conversation-1",
               ClusterMurmur.Test.FirstWeightedRandom
             )

    plan
  end

  defp persisted_conversation_plan(configuration, conversation_id) do
    persisted_event = event()
    assert {:ok, _event_record} = EventStore.insert(persisted_event)
    trigger = configuration.triggers.triggers["failure-conversation"]

    assert {:ok, authorization} =
             EventTriggerAuthorizer.authorize(
               trigger,
               persisted_event,
               @executed_at,
               TriggerExecutionStore
             )

    assert {:ok, plan} =
             EventTriggerConversationPlanner.plan(
               authorization,
               configuration,
               %{},
               conversation_id,
               ClusterMurmur.Test.FirstWeightedRandom
             )

    plan
  end

  defp authorization(configuration) do
    event = event()
    trigger = configuration.triggers.triggers["failure-conversation"]

    assert {:ok, %ExecutionPlan{} = execution_plan} =
             ClusterMurmur.Triggers.EventTriggerExecutionPlanner.plan(
               trigger,
               event,
               nil,
               @executed_at
             )

    execution =
      %TriggerExecution{
        trigger_id: trigger.id,
        event_id: event.id,
        status: :started,
        executed_at: @executed_at,
        cooldown_until: execution_plan.cooldown_until,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    authorization = %Authorization{plan: execution_plan, execution: execution}
    assert EventTriggerAuthorizer.validate(authorization) == :ok
    authorization
  end

  defp configuration do
    persona = %Persona{
      id: "caretaker",
      display_name: "Example Caretaker",
      avatar: nil,
      prompt: "State only supplied facts.",
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
      candidates: [%{persona: "caretaker", weight: 1}]
    }

    matcher = %Matcher{
      predicates: [%Predicate{field: "type", operator: :equals, value: "observation.failed"}]
    }

    trigger = %EventTrigger{
      id: "failure-conversation",
      matcher: matcher,
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

  defp event do
    %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      group: "operations",
      severity: "warning",
      occurred_at: ~U[2026-08-07 00:59:59.000000Z],
      facts: %{"detail" => "private"}
    }
  end
end

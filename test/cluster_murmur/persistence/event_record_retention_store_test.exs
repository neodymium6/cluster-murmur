defmodule ClusterMurmur.Persistence.EventRecordRetentionStoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.Events.{DedupeEvaluator, Event, RetentionPlanner}

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    EventDedupeMarker,
    EventDispatch,
    EventRecord,
    EventRecordRetentionStore,
    EventRetentionSweep,
    EventStore,
    TriggerExecution
  }

  alias ClusterMurmur.Persistence.EventRecordRetentionStore.Result
  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddEventDedupeMarkerPruneIndex,
    AddEventRetentionLookupIndexes,
    CreateConversations,
    CreateEventDedupeMarkers,
    CreateEventDispatches,
    CreateEventRetentionSweeps,
    CreateEvents,
    CreateTriggerExecutions
  }

  @events_version 20_260_804_180_500
  @executions_version 20_260_804_200_000
  @conversations_version 20_260_805_200_000
  @dispatches_version 20_260_808_150_000
  @markers_version 20_260_809_020_000
  @marker_index_version 20_260_809_043_000
  @lookup_index_version 20_260_809_050_000
  @sweeps_version 20_260_809_051_500
  @planned_at ~U[2026-08-09 06:00:00.000000Z]

  setup_all do
    migrations = [
      {@events_version, CreateEvents},
      {@executions_version, CreateTriggerExecutions},
      {@conversations_version, CreateConversations},
      {@dispatches_version, CreateEventDispatches},
      {@markers_version, CreateEventDedupeMarkers},
      {@marker_index_version, AddEventDedupeMarkerPruneIndex},
      {@lookup_index_version, AddEventRetentionLookupIndexes},
      {@sweeps_version, CreateEventRetentionSweeps}
    ]

    for {version, module} <- migrations do
      assert migrate(:up, version, module) == :ok
    end

    on_exit(fn ->
      for {version, module} <- Enum.reverse(migrations) do
        migrate(:down, version, module)
      end
    end)

    :ok
  end

  setup do
    for table <- [
          "event_dedupe_markers",
          "event_dispatches",
          "conversations",
          "trigger_executions",
          "event_retention_sweeps",
          "events"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}", [], log: false)
    end

    :ok
  end

  test "deletes only expired unreferenced events and resets a completed pass" do
    cutoff = retention_plan().cutoff

    insert_event!("unreferenced", DateTime.add(cutoff, -5, :microsecond))

    execution_event = insert_event!("execution-event", DateTime.add(cutoff, -4, :microsecond))

    conversation_event =
      insert_event!("conversation-event", DateTime.add(cutoff, -3, :microsecond))

    dispatch_event = insert_event!("dispatch-event", DateTime.add(cutoff, -2, :microsecond))
    marker_event = insert_event!("marker-event", cutoff)
    insert_event!("newer-event", DateTime.add(cutoff, 1, :microsecond))

    insert_execution!(execution_event, "trigger-a")
    insert_conversation!(conversation_event)
    insert_dispatch!(dispatch_event)
    insert_marker!(marker_event)

    assert result = EventRecordRetentionStore.prune(retention_plan())

    assert result ==
             {:ok, %Result{scanned_count: 5, pruned_event_count: 1, completed_pass?: true}}

    assert event_ids() == [
             "conversation-event",
             "dispatch-event",
             "execution-event",
             "marker-event",
             "newer-event"
           ]

    assert %EventRetentionSweep{cursor_occurred_at: nil, cursor_event_id: nil} =
             Repo.get!(EventRetentionSweep, "events")

    refute inspect(result) =~ "unreferenced"
  end

  test "advances past a full referenced page without starving later events" do
    occurred_at = DateTime.add(retention_plan().cutoff, -1, :second)

    for index <- 0..101 do
      suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")
      event = insert_event!("event-#{suffix}", occurred_at)

      if index < 100 do
        insert_execution!(event, "trigger-#{suffix}")
      end
    end

    assert EventRecordRetentionStore.prune(retention_plan()) ==
             {:ok, %Result{scanned_count: 100, pruned_event_count: 0, completed_pass?: false}}

    assert %EventRetentionSweep{
             cursor_occurred_at: ^occurred_at,
             cursor_event_id: "event-099"
           } = Repo.get!(EventRetentionSweep, "events")

    assert EventRecordRetentionStore.prune(retention_plan()) ==
             {:ok, %Result{scanned_count: 2, pruned_event_count: 2, completed_pass?: true}}

    assert length(event_ids()) == 100
    refute "event-100" in event_ids()
    refute "event-101" in event_ids()

    assert EventRecordRetentionStore.prune(retention_plan()) ==
             {:ok, %Result{scanned_count: 100, pruned_event_count: 0, completed_pass?: false}}
  end

  test "rejects malformed plans before creating sweep state" do
    plan = retention_plan()

    for candidate <- [
          nil,
          %{plan | cutoff: DateTime.add(plan.cutoff, 1, :microsecond)},
          Map.put(plan, :private, "private-value")
        ] do
      result = EventRecordRetentionStore.prune(candidate)
      assert result == {:error, :invalid_retention_plan}
      refute inspect(result) =~ "private"
    end

    assert Repo.aggregate(EventRetentionSweep, :count) == 0
  end

  test "validates only exact correlated bounded results" do
    valid = %Result{scanned_count: 100, pruned_event_count: 50, completed_pass?: false}
    assert EventRecordRetentionStore.validate_result(valid) == :ok

    invalid = [
      %{valid | scanned_count: 101},
      %{valid | pruned_event_count: 101},
      %{valid | pruned_event_count: -1},
      %{valid | completed_pass?: true},
      %{valid | scanned_count: 99, completed_pass?: false},
      Map.put(valid, :private, "private-value"),
      nil
    ]

    for result <- invalid do
      assert EventRecordRetentionStore.validate_result(result) ==
               {:error, :invalid_event_retention_result}
    end
  end

  defp retention_plan do
    policy = %EventPolicy{dedupe_window_ms: 300_000, retention_ms: 86_400_000}
    {:ok, plan} = RetentionPlanner.plan(policy, @planned_at)
    plan
  end

  defp insert_event!(id, occurred_at) do
    event = %Event{
      id: id,
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      group: "operations",
      severity: "warning",
      previous: "healthy",
      current: "unhealthy",
      occurred_at: occurred_at,
      observed_at: occurred_at,
      dedupe_key: "dedupe-#{id}",
      correlation_key: nil,
      facts: %{},
      labels: %{}
    }

    assert {:ok, %EventRecord{} = record} = EventStore.insert(event)
    record
  end

  defp insert_execution!(event, trigger_id) do
    Repo.insert!(%TriggerExecution{
      trigger_id: trigger_id,
      event_id: event.id,
      status: :completed,
      executed_at: event.occurred_at,
      cooldown_until: event.occurred_at,
      error_class: nil
    })
  end

  defp insert_conversation!(event) do
    Repo.insert!(%ConversationRecord{
      id: "conversation-a",
      root_event_id: event.id,
      status: :completed,
      turn_count: 1,
      llm_call_count: 1,
      started_at: event.occurred_at,
      completed_at: event.occurred_at
    })
  end

  defp insert_dispatch!(event) do
    Repo.insert!(%EventDispatch{
      event_id: event.id,
      status: :completed,
      enqueued_at: event.occurred_at,
      claim_token: nil,
      claim_started_at: nil,
      claim_expires_at: nil,
      completed_at: event.occurred_at
    })
  end

  defp insert_marker!(event) do
    marker = %DedupeEvaluator.Marker{
      dedupe_key: event.dedupe_key,
      event_id: event.id,
      accepted_at: event.occurred_at
    }

    %EventDedupeMarker{}
    |> EventDedupeMarker.changeset(marker)
    |> Repo.insert!()
  end

  defp event_ids do
    Repo.all(from event in EventRecord, order_by: [asc: event.id], select: event.id)
  end

  defp migrate(direction, version, module) do
    apply(Ecto.Migrator, direction, [
      Repo,
      version,
      module,
      [log: false, log_migrations_sql: false, log_migrator_sql: false]
    ])
  end
end

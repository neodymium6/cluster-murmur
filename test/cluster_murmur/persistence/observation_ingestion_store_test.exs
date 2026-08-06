defmodule ClusterMurmur.Persistence.ObservationIngestionStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Observations.{DebouncePolicy, IngestionPlanner, Observation}

  alias ClusterMurmur.Persistence.{
    EntityStateStore,
    EventRecord,
    EventStore,
    ObservationIngestionStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateEntityStates, CreateEvents}

  @event_migration_version 20_260_804_180_500
  @entity_state_migration_version 20_260_805_225_000

  setup_all do
    assert migrate_up(@event_migration_version, CreateEvents) == :ok
    assert migrate_up(@entity_state_migration_version, CreateEntityStates) == :ok

    on_exit(fn ->
      migrate_down(@entity_state_migration_version, CreateEntityStates)
      migrate_down(@event_migration_version, CreateEvents)
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM entity_states", [], log: false)
    :ok
  end

  test "commits debounce progress without inventing an event" do
    observation = observation(:unhealthy, 0)

    assert {:ok, plan} = ObservationIngestionStore.ingest(observation, policy())
    assert plan.entity_state.current_state == :unknown
    assert plan.entity_state.pending_state == :unhealthy
    assert plan.event == nil

    assert EntityStateStore.fetch(observation.source, observation.subject) ==
             {:ok, plan.entity_state}

    assert Repo.aggregate(EventRecord, :count) == 0
    assert inspect(plan) == "#ClusterMurmur.Observations.IngestionPlanner.Plan<...>"
  end

  test "commits a state transition and its factual event together" do
    assert {:ok, _pending} =
             ObservationIngestionStore.ingest(observation(:unhealthy, 0), policy())

    assert {:ok, committed} =
             ObservationIngestionStore.ingest(observation(:unhealthy, 1), policy())

    assert committed.entity_state.current_state == :unhealthy
    assert committed.event.type == "observation.failed"
    assert EventStore.fetch(committed.event.id) == {:ok, committed.event}

    assert EntityStateStore.fetch("example-observer", "example-target") ==
             {:ok, committed.entity_state}
  end

  test "rolls back state advancement when the event conflicts" do
    assert {:ok, pending} =
             ObservationIngestionStore.ingest(observation(:unhealthy, 0), policy())

    next_observation = observation(:unhealthy, 1)

    assert {:ok, projected} =
             IngestionPlanner.plan(pending.entity_state, next_observation, policy())

    conflicting_event = %{projected.event | facts: %{"sample" => 999}}
    assert {:ok, _record} = EventStore.insert(conflicting_event)

    assert ObservationIngestionStore.ingest(next_observation, policy()) ==
             {:error, :event_conflict}

    assert EntityStateStore.fetch("example-observer", "example-target") ==
             {:ok, pending.entity_state}

    assert EventStore.fetch(projected.event.id) == {:ok, conflicting_event}
  end

  test "rejects invalid values before storage and keeps stable storage errors" do
    Repo.put_dynamic_repo(:missing_observation_ingestion_repo)

    assert ObservationIngestionStore.ingest(nil, policy()) ==
             {:error, :invalid_observation}

    assert ObservationIngestionStore.ingest(observation(:healthy, 0), nil) ==
             {:error, :invalid_debounce_policy}

    assert ObservationIngestionStore.ingest(observation(:healthy, 0), policy()) ==
             {:error, :storage_unavailable}
  end

  test "rejects stale observations without changing committed state" do
    assert {:ok, committed} =
             ObservationIngestionStore.ingest(observation(:healthy, 0), policy())

    assert ObservationIngestionStore.ingest(observation(:healthy, 0), policy()) ==
             {:error, :stale_observation}

    assert EntityStateStore.fetch("example-observer", "example-target") ==
             {:ok, committed.entity_state}
  end

  defp migrate_up(version, module) do
    Ecto.Migrator.up(Repo, version, module,
      log: false,
      log_migrations_sql: false,
      log_migrator_sql: false
    )
  end

  defp migrate_down(version, module) do
    Ecto.Migrator.down(Repo, version, module,
      log: false,
      log_migrations_sql: false,
      log_migrator_sql: false
    )
  end

  defp policy, do: %DebouncePolicy{healthy_threshold: 2, unhealthy_threshold: 2}

  defp observation(state, offset) do
    %Observation{
      source: "example-observer",
      subject: "example-target",
      state: state,
      observed_at: DateTime.add(~U[2026-08-06 12:00:00.000000Z], offset, :second),
      facts: %{"sample" => offset},
      labels: %{"category" => "monitoring"}
    }
  end
end

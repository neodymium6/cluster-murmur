defmodule ClusterMurmur.Persistence.EntityStateStoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Observations.EntityState

  alias ClusterMurmur.Persistence.{
    EntityStateRecord,
    EntityStateRecordValidator,
    EntityStateStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreateEntityStates

  @migration_version 20_260_805_225_000

  setup_all do
    assert Ecto.Migrator.up(Repo, @migration_version, CreateEntityStates,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @migration_version, CreateEntityStates,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM entity_states", [], log: false)
    :ok
  end

  test "restores no state for an unknown bounded identity" do
    assert EntityStateStore.fetch("example-observer", "example-target") == {:ok, nil}
  end

  test "records and restores exact redacted state" do
    state = entity_state([])
    assert {:ok, record} = EntityStateStore.put(state)
    assert EntityStateRecordValidator.validate(record) == :ok
    assert EntityStateStore.fetch(state.source, state.subject) == {:ok, state}
    refute inspect(record) =~ state.source
    refute inspect(record) =~ "attempts"
  end

  test "treats an exact retry as idempotent" do
    state = entity_state([])
    assert {:ok, first} = EntityStateStore.put(state)
    assert EntityStateStore.put(state) == {:ok, first}
    assert Repo.aggregate(EntityStateRecord, :count) == 1
  end

  test "monotonically replaces an older exact state" do
    assert {:ok, _first} = EntityStateStore.put(entity_state([]))

    next =
      entity_state(
        current_state: :unhealthy,
        pending_state: nil,
        consecutive_count: 0,
        last_observed_at: ~U[2026-08-05 12:01:00.000000Z],
        last_changed_at: ~U[2026-08-05 12:01:00.000000Z],
        facts: %{"attempts" => 3}
      )

    assert {:ok, updated} = EntityStateStore.put(next)
    assert EntityStateRecordValidator.validate(updated) == :ok
    assert EntityStateStore.fetch(next.source, next.subject) == {:ok, next}
    assert Repo.aggregate(EntityStateRecord, :count) == 1
  end

  test "retries one CAS miss after an intermediate valid write" do
    assert {:ok, _first} = EntityStateStore.put(entity_state([]))

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER advance_entity_state_before_update
      BEFORE UPDATE ON entity_states
      WHEN OLD.last_observed_at = '2026-08-05T12:00:00.000000Z'
      BEGIN
        UPDATE entity_states
        SET last_observed_at = '2026-08-05T12:00:30.000000Z'
        WHERE source = OLD.source AND subject = OLD.subject;
        SELECT RAISE(IGNORE);
      END
      """,
      [],
      log: false
    )

    next = entity_state(last_observed_at: later(), facts: %{"attempts" => 3})

    try do
      assert {:ok, _record} = EntityStateStore.put(next)
      assert EntityStateStore.fetch(next.source, next.subject) == {:ok, next}
    after
      Ecto.Adapters.SQL.query!(
        Repo,
        "DROP TRIGGER advance_entity_state_before_update",
        [],
        log: false
      )
    end
  end

  test "rejects stale and conflicting equal-time updates" do
    state = entity_state([])
    assert {:ok, first} = EntityStateStore.put(state)

    assert EntityStateStore.put(entity_state(last_observed_at: ~U[2026-08-05 11:59:59.999999Z])) ==
             {:error, :entity_state_conflict}

    assert EntityStateStore.put(entity_state(facts: %{"attempts" => 3})) ==
             {:error, :entity_state_conflict}

    assert Repo.get_by!(EntityStateRecord,
             source: state.source,
             subject: state.subject
           ) == first
  end

  test "rejects invalid values before storage access" do
    Repo.put_dynamic_repo(:missing_entity_state_repo)

    for identity <- [nil, "", <<255>>, String.duplicate("a", 16 * 1_024 + 1)] do
      assert EntityStateStore.fetch(identity, "example-target") ==
               {:error, :invalid_entity_identity}

      assert EntityStateStore.fetch("example-observer", identity) ==
               {:error, :invalid_entity_identity}
    end

    assert EntityStateStore.put(%{entity_state([]) | consecutive_count: -1}) ==
             {:error, :invalid_entity_state}
  end

  test "fails closed on invalid durable JSON" do
    state = entity_state([])
    assert {:ok, _record} = EntityStateStore.put(state)

    Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = ON", [], log: false)

    try do
      assert {1, nil} =
               Repo.update_all(
                 from(record in EntityStateRecord,
                   where: record.source == ^state.source and record.subject == ^state.subject
                 ),
                 set: [facts: ~s({"duplicate":1,"duplicate":2})]
               )
    after
      Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = OFF", [], log: false)
    end

    assert EntityStateStore.fetch(state.source, state.subject) ==
             {:error, :invalid_entity_state_record}

    assert EntityStateStore.put(%{state | last_observed_at: later()}) ==
             {:error, :invalid_entity_state_record}
  end

  test "returns generic storage failures without exposing identity" do
    Repo.put_dynamic_repo(:missing_entity_state_repo)

    for result <- [
          EntityStateStore.fetch("private-source", "private-subject"),
          EntityStateStore.put(entity_state(source: "private-source", subject: "private-subject"))
        ] do
      assert result == {:error, :storage_unavailable}
      refute inspect(result) =~ "private"
    end
  end

  defp later, do: ~U[2026-08-05 12:01:00.000000Z]

  defp entity_state(overrides) do
    struct!(
      EntityState,
      Keyword.merge(
        [
          source: "example-observer",
          subject: "example-target",
          current_state: :healthy,
          pending_state: nil,
          consecutive_count: 0,
          last_observed_at: ~U[2026-08-05 12:00:00.000000Z],
          last_changed_at: ~U[2026-08-05 11:00:00.000000Z],
          facts: %{"attempts" => 2},
          labels: %{"category" => "monitoring"}
        ],
        overrides
      )
    )
  end
end

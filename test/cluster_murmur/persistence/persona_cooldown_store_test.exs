defmodule ClusterMurmur.Persistence.PersonaCooldownStoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Persistence.{
    PersonaCooldownRecord,
    PersonaCooldownRecordValidator,
    PersonaCooldownStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreatePersonaCooldowns

  @migration_version 20_260_805_224_000

  setup_all do
    assert Ecto.Migrator.up(Repo, @migration_version, CreatePersonaCooldowns,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @migration_version, CreatePersonaCooldowns,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM persona_cooldowns", [], log: false)
    :ok
  end

  test "restores no cooldown for a bounded unknown persona" do
    assert PersonaCooldownStore.fetch("observer") == {:ok, nil}
  end

  test "records and restores one exact redacted cooldown" do
    assert {:ok, record} = record_spoken()
    assert PersonaCooldownRecordValidator.validate(record) == :ok
    assert record.persona_id == "observer"
    assert record.last_spoken_at == spoken_at()
    assert record.cooldown_until == cooldown_until()
    assert PersonaCooldownStore.fetch("observer") == {:ok, record}
    refute inspect(record) =~ "observer"
    refute inspect(record) =~ "2026"
  end

  test "treats an exact retry as idempotent" do
    assert {:ok, first} = record_spoken()

    assert PersonaCooldownStore.record_spoken("observer", spoken_at(), cooldown_until()) ==
             {:ok, first}

    assert Repo.aggregate(PersonaCooldownRecord, :count) == 1
  end

  test "monotonically replaces an older exact cooldown" do
    assert {:ok, _first} = record_spoken()
    later_spoken_at = DateTime.add(spoken_at(), 60, :second)
    later_deadline = DateTime.add(later_spoken_at, 30 * 60, :second)

    assert {:ok, updated} =
             PersonaCooldownStore.record_spoken("observer", later_spoken_at, later_deadline)

    assert updated.last_spoken_at == later_spoken_at
    assert updated.cooldown_until == later_deadline
    assert PersonaCooldownStore.fetch("observer") == {:ok, updated}
    assert Repo.aggregate(PersonaCooldownRecord, :count) == 1
  end

  test "rejects stale or conflicting equal-time updates" do
    assert {:ok, first} = record_spoken()

    assert PersonaCooldownStore.record_spoken(
             "observer",
             DateTime.add(spoken_at(), -1, :microsecond),
             cooldown_until()
           ) == {:error, :persona_cooldown_conflict}

    assert PersonaCooldownStore.record_spoken(
             "observer",
             spoken_at(),
             DateTime.add(cooldown_until(), 1, :second)
           ) == {:error, :persona_cooldown_conflict}

    assert Repo.get!(PersonaCooldownRecord, "observer") == first
  end

  test "rejects invalid inputs before accessing storage" do
    Repo.put_dynamic_repo(:missing_persona_cooldown_repo)

    for persona_id <- [nil, "", "invalid id", String.duplicate("a", 16 * 1_024 + 1)] do
      assert PersonaCooldownStore.fetch(persona_id) == {:error, :invalid_persona_id}

      assert PersonaCooldownStore.record_spoken(persona_id, spoken_at(), cooldown_until()) ==
               {:error, :invalid_persona_cooldown}
    end

    for {last_spoken_at, deadline} <- [
          {nil, cooldown_until()},
          {spoken_at(), nil},
          {%{spoken_at() | hour: 24}, cooldown_until()},
          {spoken_at(), DateTime.add(spoken_at(), -1, :microsecond)},
          {spoken_at(), DateTime.add(spoken_at(), 365 * 86_400 + 1, :second)}
        ] do
      assert PersonaCooldownStore.record_spoken("observer", last_spoken_at, deadline) ==
               {:error, :invalid_persona_cooldown}
    end
  end

  test "fails closed on an invalid durable record" do
    assert {:ok, _record} = record_spoken()

    Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = ON", [], log: false)

    try do
      assert {1, nil} =
               Repo.update_all(
                 from(record in PersonaCooldownRecord,
                   where: record.persona_id == "observer"
                 ),
                 set: [cooldown_until: DateTime.add(spoken_at(), -1, :microsecond)]
               )
    after
      Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = OFF", [], log: false)
    end

    assert PersonaCooldownStore.fetch("observer") ==
             {:error, :invalid_persona_cooldown_record}

    assert PersonaCooldownStore.record_spoken("observer", spoken_at(), cooldown_until()) ==
             {:error, :invalid_persona_cooldown_record}
  end

  test "rolls back a valid durable rewrite instead of returning altered facts" do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER rewrite_persona_cooldown
      AFTER INSERT ON persona_cooldowns
      BEGIN
        UPDATE persona_cooldowns
        SET last_spoken_at = NEW.cooldown_until
        WHERE persona_id = NEW.persona_id;
      END
      """,
      [],
      log: false
    )

    try do
      assert record_spoken() == {:error, :persona_cooldown_conflict}
      assert Repo.aggregate(PersonaCooldownRecord, :count) == 0
    after
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER rewrite_persona_cooldown", [], log: false)
    end
  end

  test "returns generic storage errors without exposing values" do
    Repo.put_dynamic_repo(:missing_persona_cooldown_repo)

    for result <- [
          PersonaCooldownStore.fetch("private-persona"),
          PersonaCooldownStore.record_spoken(
            "private-persona",
            spoken_at(),
            cooldown_until()
          )
        ] do
      assert result == {:error, :storage_unavailable}
      refute inspect(result) =~ "private"
    end
  end

  defp record_spoken do
    PersonaCooldownStore.record_spoken("observer", spoken_at(), cooldown_until())
  end

  defp spoken_at, do: ~U[2026-08-05 12:00:00.000000Z]
  defp cooldown_until, do: ~U[2026-08-05 12:30:00.000000Z]
end

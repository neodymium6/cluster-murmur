defmodule ClusterMurmur.Persistence.EntityStateMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.EntityStateRecord
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

  test "persists the fixed entity-state shape with a composite identity" do
    assert {:ok, first} = Repo.insert(valid_record())
    assert first.source == "example-observer"
    assert first.subject == "example-target"
    assert Repo.aggregate(EntityStateRecord, :count) == 1

    assert_raise Ecto.ConstraintError, fn -> Repo.insert(valid_record()) end
  end

  test "database constraints reject invalid progress and changed times" do
    invalid = [
      %{valid_record() | current_state: :unknown, pending_state: nil, last_changed_at: nil},
      %{
        valid_record()
        | current_state: :unknown,
          pending_state: nil,
          consecutive_count: 1,
          last_changed_at: nil
      },
      %{valid_record() | pending_state: nil, consecutive_count: 5},
      %{valid_record() | pending_state: :healthy, consecutive_count: 1},
      %{valid_record() | pending_state: :unhealthy, consecutive_count: 0},
      %{valid_record() | last_changed_at: ~U[2026-08-05 12:00:00.000001Z]}
    ]

    for record <- invalid do
      assert_raise Ecto.ConstraintError, fn -> Repo.insert(record) end
    end
  end

  test "database constraints reject malformed payloads" do
    for record <- [
          %{valid_record() | facts: "null"},
          %{valid_record() | labels: "[]"},
          %{valid_record() | facts: String.duplicate(" ", 128 * 1_024)}
        ] do
      assert_raise Ecto.ConstraintError, fn -> Repo.insert(record) end
    end
  end

  defp valid_record do
    %EntityStateRecord{
      source: "example-observer",
      subject: "example-target",
      current_state: :healthy,
      pending_state: nil,
      consecutive_count: 0,
      last_observed_at: ~U[2026-08-05 12:00:00.000000Z],
      last_changed_at: ~U[2026-08-05 11:00:00.000000Z],
      facts: "{}",
      labels: "{}"
    }
  end
end

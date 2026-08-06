defmodule ClusterMurmur.Persistence.PersonaCooldownMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreatePersonaCooldowns
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @migration_version 20_260_805_224_000

  test "migrates a constrained persona cooldown table" do
    {root, database} = private_database_path()

    assert {:ok, pid} =
             Repo.start_link(
               name: nil,
               database: database,
               allow_in_memory: false,
               pool_size: 1
             )

    try do
      migrate_up(pid)

      assert table_columns(pid) == ["persona_id", "cooldown_until", "last_spoken_at"]

      assert {:ok, _result} = insert_cooldown(pid, %{})

      for overrides <- [
            %{persona_id: "invalid id"},
            %{persona_id: ""},
            %{cooldown_until: "not-a-datetime"},
            %{last_spoken_at: "not-a-datetime"},
            %{cooldown_until: "2026-08-05T11:59:59.999999Z"},
            %{cooldown_until: "2027-08-05T12:00:00.000001Z"}
          ] do
        assert_constraint(fn -> insert_cooldown(pid, overrides) end)
      end

      assert_constraint(fn -> insert_cooldown(pid, %{}) end)

      migrate_down(pid)
      refute "persona_cooldowns" in table_names(pid)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp insert_cooldown(repo, overrides) do
    values =
      Map.merge(
        %{
          persona_id: "observer",
          cooldown_until: "2026-08-05T12:30:00.000000Z",
          last_spoken_at: "2026-08-05T12:00:00.000000Z"
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO persona_cooldowns (persona_id, cooldown_until, last_spoken_at)
      VALUES (?, ?, ?)
      """,
      [values.persona_id, values.cooldown_until, values.last_spoken_at],
      log: false
    )
  end

  defp migrate_up(repo) do
    assert Ecto.Migrator.up(Repo, @migration_version, CreatePersonaCooldowns,
             dynamic_repo: repo,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end

  defp migrate_down(repo) do
    assert Ecto.Migrator.down(Repo, @migration_version, CreatePersonaCooldowns,
             dynamic_repo: repo,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end

  defp table_columns(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(persona_cooldowns)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp table_names(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT name FROM sqlite_master WHERE type = 'table'",
        [],
        log: false
      )

    List.flatten(rows)
  end

  defp assert_constraint(fun) do
    assert {:error, %Exqlite.Error{message: message}} = fun.()
    assert message =~ "constraint failed"
  end

  defp private_database_path do
    root = PrivateTmpDir.create!("cluster-murmur-persona-cooldown-migration")
    {root, Path.join(root, "migration.sqlite3")}
  end
end

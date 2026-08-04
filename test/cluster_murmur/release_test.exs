defmodule ClusterMurmur.ReleaseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias ClusterMurmur.{Release, Repo}

  @migration_versions [20_260_804_130_000, 20_260_804_160_000]

  setup do
    original_repo_config = Application.fetch_env!(:cluster_murmur, Repo)
    original_repos = Application.fetch_env!(:cluster_murmur, :ecto_repos)
    {:ok, _started} = Application.ensure_all_started(:cluster_murmur)
    :ok = stop_application()
    :ok = stop_migration_dependencies()

    root = private_database_root()
    database = Path.join(root, "release.sqlite3")

    Application.put_env(
      :cluster_murmur,
      Repo,
      original_repo_config
      |> Keyword.put(:database, database)
      |> Keyword.put(:allow_in_memory, false)
    )

    on_exit(fn ->
      if application_started?(:cluster_murmur), do: stop_application()

      Application.put_env(:cluster_murmur, Repo, original_repo_config)
      Application.put_env(:cluster_murmur, :ecto_repos, original_repos)
      {:ok, _started} = Application.ensure_all_started(:cluster_murmur)
      File.rm_rf!(root)
    end)

    %{database: database, root: root}
  end

  test "applies packaged migrations while stopped and remains idempotent", %{database: database} do
    refute File.exists?(database)
    started_before = started_application_names()

    migration_stderr =
      capture_io(:stderr, fn ->
        assert Release.migrate() == :ok
        assert Release.migrate() == :ok
      end)

    refute migration_stderr =~ database
    refute application_started?(:cluster_murmur)
    refute Process.whereis(Repo)
    assert started_application_names() == started_before

    {:ok, _started} = Application.ensure_all_started(:cluster_murmur)

    assert table_exists?("stochastic_schedules")
    assert migrated_versions() == @migration_versions
  end

  test "rejects a running application and repository" do
    {:ok, _started} = Application.ensure_all_started(:cluster_murmur)

    assert Process.whereis(Repo)
    assert Release.migrate() == {:error, :migration_failed}

    assert_raise RuntimeError, "database migration failed", fn ->
      Release.migrate!()
    end

    refute table_exists?("stochastic_schedules")
  end

  test "rejects an unexpected repository set without creating storage", %{database: database} do
    Application.put_env(:cluster_murmur, :ecto_repos, [Example.UnexpectedRepo])

    assert Release.migrate() == {:error, :migration_failed}
    refute File.exists?(database)
  end

  test "suppresses startup diagnostics and returns only generic failure", %{
    database: database,
    root: root
  } do
    rejected_database = Path.join([root, "missing", "sensitive-marker.sqlite3"])
    config = Application.fetch_env!(:cluster_murmur, Repo)
    Application.put_env(:cluster_murmur, Repo, Keyword.put(config, :database, rejected_database))
    caller = self()
    started_before = started_application_names()

    standard_error =
      capture_io(:stderr, fn ->
        logs =
          capture_log(fn ->
            assert Release.migrate() == {:error, :migration_failed}

            assert_raise RuntimeError, "database migration failed", fn ->
              Release.migrate!()
            end
          end)

        send(caller, {:captured_logs, logs})
      end)

    assert_receive {:captured_logs, logs}
    diagnostics = standard_error <> logs

    refute diagnostics =~ rejected_database
    refute diagnostics =~ "sensitive-marker"
    refute File.exists?(database)
    refute Process.whereis(Repo)
    assert started_application_names() == started_before
  end

  test "rejects an overlapping migration before changing logging or storage", %{
    database: database
  } do
    parent = self()

    holder =
      spawn(fn ->
        lock = {{Release, :migration}, self()}
        true = :global.set_lock(lock, [node()], 0)
        send(parent, {:migration_lock_held, self()})

        receive do
          :release_migration_lock -> :global.del_lock(lock, [node()])
        end
      end)

    assert_receive {:migration_lock_held, ^holder}
    %{level: logging_level} = :logger.get_primary_config()

    assert Release.migrate() == {:error, :migration_failed}
    assert :logger.get_primary_config()[:level] == logging_level
    refute File.exists?(database)

    send(holder, :release_migration_lock)
  end

  defp private_database_root do
    root =
      Path.join(System.tmp_dir!(), "cluster-murmur-release-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    root
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {started, _description, _version} ->
      started == application
    end)
  end

  defp started_application_names do
    Application.started_applications()
    |> Enum.map(fn {application, _description, _version} -> application end)
    |> MapSet.new()
  end

  defp stop_application do
    capture_log(fn -> assert Application.stop(:cluster_murmur) == :ok end)
    :ok
  end

  defp stop_migration_dependencies do
    capture_log(fn ->
      for application <- [:ecto_sqlite3, :exqlite, :ecto_sql],
          application_started?(application) do
        assert Application.stop(application) == :ok
      end
    end)

    :ok
  end

  defp table_exists?(name) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name],
        log: false
      )

    rows == [[name]]
  end

  defp migrated_versions do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT version FROM schema_migrations ORDER BY version", [],
        log: false
      )

    List.flatten(rows)
  end
end

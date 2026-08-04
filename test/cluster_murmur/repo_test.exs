defmodule ClusterMurmur.RepoTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo

  test "starts the supervised repository with an isolated test database" do
    assert Process.whereis(Repo)
    assert Repo.config()[:database] == ":memory:"
    refute Keyword.has_key?(Repo.config(), :allow_in_memory)

    assert {:ok, %{columns: ["answer"], rows: [[1]]}} =
             Ecto.Adapters.SQL.query(Repo, "SELECT 1 AS answer", [])
  end

  test "enables bounded single-writer connection settings" do
    assert {:ok, %{rows: [[1]]}} = Ecto.Adapters.SQL.query(Repo, "PRAGMA foreign_keys", [])

    assert Repo.config()[:pool_size] == 1
    assert Repo.config()[:default_transaction_mode] == :immediate
    assert Repo.config()[:busy_timeout] == 5_000
    assert Repo.config()[:journal_mode] == :wal
    assert Repo.config()[:log] == false
    assert Repo.config()[:show_sensitive_data_on_connection_error] == false
  end

  test "classifies unsafe or missing database configuration without returning paths" do
    assert_raise ArgumentError, "invalid database configuration", fn ->
      Repo.init(:runtime, [])
    end

    invalid = [
      [database: ":memory:", allow_in_memory: false],
      [database: "relative.sqlite3"],
      [database: "/tmp/invalid\0.sqlite3"],
      [database: <<0>>],
      [database: nil]
    ]

    for config <- invalid do
      result = start_repo(config)

      assert {:error, {%ArgumentError{message: "invalid database configuration"}, _stacktrace}} =
               result

      refute inspect(result) =~ "sqlite3"
    end
  end

  test "creates a private database file in pre-existing private storage" do
    root = private_test_root()
    directory = Path.join(root, "storage")
    database = Path.join(directory, "cluster-murmur.sqlite3")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    assert {:ok, pid} =
             Repo.start_link(name: nil, database: database, allow_in_memory: false)

    Supervisor.stop(pid)

    assert {:ok, %File.Stat{type: :directory, mode: directory_mode}} = File.lstat(directory)
    assert Bitwise.band(directory_mode, 0o777) == 0o700

    assert {:ok, %File.Stat{type: :regular, mode: database_mode}} = File.lstat(database)
    assert Bitwise.band(database_mode, 0o777) == 0o600
  end

  test "rejects public storage permissions and symlink targets without exposing paths" do
    root = private_test_root()
    public_directory = Path.join(root, "public-storage")
    File.mkdir_p!(public_directory)
    File.chmod!(public_directory, 0o755)

    private_directory = Path.join(root, "private-storage")
    File.mkdir_p!(private_directory)
    File.chmod!(private_directory, 0o700)
    public_database = Path.join(private_directory, "public.sqlite3")
    File.write!(public_database, "")
    File.chmod!(public_database, 0o644)

    linked_directory = Path.join(root, "linked-storage")
    File.ln_s!(private_directory, linked_directory)

    databases = [
      Path.join([root, "missing-storage", "new.sqlite3"]),
      Path.join(public_directory, "new.sqlite3"),
      public_database,
      Path.join(linked_directory, "linked.sqlite3")
    ]

    for database <- databases do
      result = start_repo(database: database, allow_in_memory: false)

      assert {:error, {%ArgumentError{message: "invalid database configuration"}, _stacktrace}} =
               result

      refute inspect(result) =~ database
    end
  end

  test "rejects Ecto URL overrides before they can replace validated settings" do
    root = private_test_root()
    database = Path.join(root, "unused.sqlite3")

    result =
      start_repo(
        database: database,
        allow_in_memory: false,
        url: "ecto://example.invalid/:memory:"
      )

    assert {:error, {%ArgumentError{message: "invalid database configuration"}, _stacktrace}} =
             result

    refute inspect(result) =~ ":memory:"
    refute File.exists?(database)
  end

  test "runtime configuration validation does not create storage" do
    root = private_test_root()
    database = Path.join([root, "not-created", "cluster-murmur.sqlite3"])

    assert {:ok, config} =
             Repo.init(:runtime, database: database, allow_in_memory: false)

    assert config[:database] == database
    refute Keyword.has_key?(config, :allow_in_memory)
    refute File.exists?(Path.dirname(database))
  end

  defp start_repo(config) do
    trapping_exits? = Process.flag(:trap_exit, true)

    try do
      Repo.start_link(Keyword.put(config, :name, nil))
    after
      Process.flag(:trap_exit, trapping_exits?)
    end
  end

  defp private_test_root do
    root =
      Path.join(System.tmp_dir!(), "cluster-murmur-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end

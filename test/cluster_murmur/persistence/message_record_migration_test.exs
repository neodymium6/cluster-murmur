defmodule ClusterMurmur.Persistence.MessageRecordMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    CreateConversations,
    CreateEvents,
    CreateMessages
  }

  @events_version 20_260_804_180_500
  @conversations_version 20_260_805_200_000
  @messages_version 20_260_805_220_000

  test "migrates a constrained generated-message table" do
    {root, database} = private_database_path()

    assert {:ok, pid} =
             Repo.start_link(
               name: nil,
               database: database,
               allow_in_memory: false,
               pool_size: 1
             )

    try do
      migrate_up(pid, @events_version, CreateEvents)
      migrate_up(pid, @conversations_version, CreateConversations)
      migrate_up(pid, @messages_version, CreateMessages)

      assert table_columns(pid) == [
               "id",
               "conversation_id",
               "persona_id",
               "origin",
               "content",
               "discord_message_id",
               "inserted_at"
             ]

      index_rows = indexes(pid)

      assert Enum.any?(
               index_rows,
               &Enum.member?(&1, "messages_conversation_id_inserted_at_id_index")
             )

      assert Enum.any?(index_rows, &Enum.member?(&1, "messages_discord_message_id_index"))

      assert {:ok, _result} = insert_event(pid)
      assert {:ok, _result} = insert_conversation(pid)
      assert {:ok, _result} = insert_message(pid, %{discord_message_id: "12345"})

      for overrides <- [
            %{conversation_id: "missing-conversation"},
            %{persona_id: "invalid persona"},
            %{origin: "system"},
            %{content: ""},
            %{content: "  "},
            %{content: "\t\n\r"},
            %{content: "\u00A0\u2003\u3000"},
            %{content: "\u200B\u200D\uFEFF"},
            %{content: "hidden\0content"},
            %{content: String.duplicate("a", 16 * 1_024 + 1)},
            %{discord_message_id: "0"},
            %{discord_message_id: "000123"},
            %{discord_message_id: "message-1"},
            %{discord_message_id: "123\0x"},
            %{discord_message_id: "18446744073709551616"},
            %{inserted_at: "not-a-datetime"}
          ] do
        assert_constraint(fn -> insert_message(pid, overrides) end)
      end

      assert {:ok, _result} =
               insert_message(pid, %{discord_message_id: nil, content: "A second bounded fact."})

      assert_constraint(fn ->
        insert_message(pid, %{
          content: "A duplicate publication.",
          discord_message_id: "12345"
        })
      end)

      migrate_down(pid, @messages_version, CreateMessages)
      refute "messages" in table_names(pid)
      migrate_down(pid, @conversations_version, CreateConversations)
      migrate_down(pid, @events_version, CreateEvents)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp insert_event(repo) do
    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO events (id, type, source, facts, labels, occurred_at, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "event-1",
        "observation.failed",
        "example-observer",
        "{}",
        "{}",
        "2026-08-05T11:59:59.000000Z",
        "2026-08-05T12:00:00.000000Z"
      ],
      log: false
    )
  end

  defp insert_conversation(repo) do
    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO conversations
        (id, root_event_id, status, turn_count, llm_call_count, started_at, completed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "conversation-1",
        "event-1",
        "waiting",
        1,
        1,
        "2026-08-05T12:00:00.000000Z",
        nil
      ],
      log: false
    )
  end

  defp insert_message(repo, overrides) do
    values =
      Map.merge(
        %{
          conversation_id: "conversation-1",
          persona_id: "observer",
          origin: "llm",
          content: "A bounded fact.",
          discord_message_id: nil,
          inserted_at: "2026-08-05T12:01:00.000000Z"
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO messages
        (conversation_id, persona_id, origin, content, discord_message_id, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        values.conversation_id,
        values.persona_id,
        values.origin,
        values.content,
        values.discord_message_id,
        values.inserted_at
      ],
      log: false
    )
  end

  defp migrate_up(repo, version, migration) do
    assert Ecto.Migrator.up(Repo, version, migration,
             dynamic_repo: repo,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end

  defp migrate_down(repo, version, migration) do
    assert Ecto.Migrator.down(Repo, version, migration,
             dynamic_repo: repo,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end

  defp table_columns(repo) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(messages)", [], log: false)
    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp indexes(repo) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(messages)", [], log: false)
    rows
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
    root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-message-migration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {root, Path.join(root, "migration.sqlite3")}
  end
end

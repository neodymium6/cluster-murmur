defmodule ClusterMurmur.Persistence.PublicationAttemptStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Discord.{PublicationPlanner, WebhookSettings}

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    EventRecord,
    MessageRecord,
    PublicationAttemptRecord,
    PublicationAttemptStore
  }

  alias ClusterMurmur.Personas.Persona
  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddPublicationAttemptDispatching,
    CreateConversations,
    CreateEvents,
    CreateMessages,
    CreatePublicationAttempts
  }

  @event_version 20_260_804_180_500
  @conversation_version 20_260_805_200_000
  @message_version 20_260_805_220_000
  @attempt_version 20_260_805_230_000
  @dispatching_version 20_260_805_231_000

  setup_all do
    for {version, migration} <- [
          {@event_version, CreateEvents},
          {@conversation_version, CreateConversations},
          {@message_version, CreateMessages},
          {@attempt_version, CreatePublicationAttempts},
          {@dispatching_version, AddPublicationAttemptDispatching}
        ] do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- [
            {@dispatching_version, AddPublicationAttemptDispatching},
            {@attempt_version, CreatePublicationAttempts},
            {@message_version, CreateMessages},
            {@conversation_version, CreateConversations},
            {@event_version, CreateEvents}
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
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM publication_attempts", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM messages", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM conversations", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)

    Repo.insert!(%EventRecord{
      id: "event-1",
      type: "observation.failed",
      source: "example-observer",
      facts: "{}",
      labels: "{}",
      occurred_at: ~U[2026-08-05 12:00:00.000000Z],
      inserted_at: ~U[2026-08-05 12:00:00.000000Z]
    })

    Repo.insert!(%ConversationRecord{
      id: "conversation-1",
      root_event_id: "event-1",
      status: :generating,
      turn_count: 1,
      llm_call_count: 1,
      started_at: ~U[2026-08-05 12:00:00.000000Z]
    })

    message =
      Repo.insert!(%MessageRecord{
        conversation_id: "conversation-1",
        persona_id: "observer",
        origin: :llm,
        content: "A bounded confirmed fact.",
        inserted_at: ~U[2026-08-05 12:01:00.000000Z]
      })

    {:ok, message: message}
  end

  test "starts, restores, and idempotently repeats one exact attempt", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, first} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert first.status == :started
    assert PublicationAttemptStore.fetch(message.id) == {:ok, first}

    assert PublicationAttemptStore.start(plan, message, persona, settings, started_at()) ==
             {:ok, first}

    assert Repo.aggregate(PublicationAttemptRecord, :count) == 1
  end

  test "normalizes valid UTC precision before durable comparison", %{message: message} do
    {plan, persona, settings} = plan(message)

    for precision <- [0, 3] do
      supplied = %{started_at() | microsecond: {0, precision}}

      assert {:ok, attempt} =
               PublicationAttemptStore.start(plan, message, persona, settings, supplied)

      assert attempt.started_at.microsecond == {0, 6}

      assert PublicationAttemptStore.start(plan, message, persona, settings, started_at()) ==
               {:ok, attempt}

      Repo.delete_all(PublicationAttemptRecord)
    end
  end

  test "closes a started attempt with one classified failure idempotently", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    completed_at = %{completed_at() | microsecond: {0, 3}}

    assert {:ok, failed} = PublicationAttemptStore.fail(started, :timeout, completed_at)
    assert failed.status == :failed
    assert failed.error_class == :timeout
    assert failed.completed_at.microsecond == {0, 6}
    assert PublicationAttemptStore.fail(started, :timeout, completed_at()) == {:ok, failed}
    assert PublicationAttemptStore.fetch(message.id) == {:ok, failed}
  end

  test "closes a started attempt with one ambiguous interruption idempotently", %{
    message: message
  } do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, ambiguous} =
             PublicationAttemptStore.mark_ambiguous(started, completed_at())

    assert ambiguous.status == :ambiguous
    assert ambiguous.error_class == :interrupted

    assert PublicationAttemptStore.mark_ambiguous(started, completed_at()) ==
             {:ok, ambiguous}
  end

  test "grants exactly one durable dispatch claim", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)
    assert dispatching.status == :dispatching
    assert dispatching.started_at == started.started_at
    assert dispatching.completed_at == nil
    assert dispatching.error_class == nil
    assert PublicationAttemptStore.fetch(message.id) == {:ok, dispatching}

    assert PublicationAttemptStore.claim_dispatch(started) ==
             {:error, :publication_attempt_conflict}

    assert PublicationAttemptStore.claim_dispatch(dispatching) ==
             {:error, :invalid_publication_attempt_record}
  end

  test "requires a dispatch claim before recording success", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    Repo.put_dynamic_repo(:missing_publication_attempt_repo)

    assert PublicationAttemptStore.succeed(started, message, "12345", completed_at()) ==
             {:error, :invalid_publication_attempt_record}
  end

  test "rolls back a rewritten dispatch claim", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER rewrite_dispatch_claim
      AFTER UPDATE OF status ON publication_attempts
      BEGIN
        UPDATE publication_attempts
        SET started_at = '2026-08-05T12:02:01.000000Z'
        WHERE message_id = NEW.message_id;
      END
      """,
      [],
      log: false
    )

    try do
      assert PublicationAttemptStore.claim_dispatch(started) ==
               {:error, :publication_attempt_conflict}

      assert PublicationAttemptStore.fetch(message.id) == {:ok, started}
    after
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER rewrite_dispatch_claim", [], log: false)
    end
  end

  test "returns a generic dispatch-claim storage failure", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    Repo.put_dynamic_repo(:missing_publication_attempt_repo)
    assert PublicationAttemptStore.claim_dispatch(started) == {:error, :storage_unavailable}
  end

  test "closes dispatch claims as known failure or ambiguous interruption", %{message: message} do
    {plan, persona, settings} = plan(message)

    for {operation, expected_status, expected_error} <- [
          {fn attempt -> PublicationAttemptStore.fail(attempt, :timeout, completed_at()) end,
           :failed, :timeout},
          {fn attempt -> PublicationAttemptStore.mark_ambiguous(attempt, completed_at()) end,
           :ambiguous, :interrupted}
        ] do
      assert {:ok, started} =
               PublicationAttemptStore.start(plan, message, persona, settings, started_at())

      assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)
      assert {:ok, terminal} = operation.(dispatching)
      assert terminal.status == expected_status
      assert terminal.error_class == expected_error
      Repo.delete_all(PublicationAttemptRecord)
    end
  end

  test "atomically records one known publication success idempotently", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)

    assert {:ok, {succeeded, published}} =
             PublicationAttemptStore.succeed(dispatching, message, "12345", completed_at())

    assert succeeded.status == :succeeded
    assert succeeded.completed_at == completed_at()
    assert succeeded.error_class == nil
    assert published.discord_message_id == "12345"

    assert PublicationAttemptStore.succeed(dispatching, message, "12345", completed_at()) ==
             {:ok, {succeeded, published}}

    assert PublicationAttemptStore.fetch(message.id) == {:ok, succeeded}
    assert Repo.get!(MessageRecord, message.id) == published
  end

  test "does not reinterpret a known success", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)

    assert {:ok, {succeeded, published}} =
             PublicationAttemptStore.succeed(dispatching, message, "12345", completed_at())

    assert PublicationAttemptStore.succeed(dispatching, message, "67890", completed_at()) ==
             {:error, :publication_attempt_conflict}

    assert PublicationAttemptStore.succeed(
             dispatching,
             message,
             "12345",
             DateTime.add(completed_at(), 1, :microsecond)
           ) == {:error, :publication_attempt_conflict}

    assert PublicationAttemptStore.fail(dispatching, :timeout, completed_at()) ==
             {:error, :publication_attempt_conflict}

    assert PublicationAttemptStore.fetch(message.id) == {:ok, succeeded}
    assert Repo.get!(MessageRecord, message.id) == published
  end

  test "rolls back the attempt when the Discord ID conflicts", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, first_attempt} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, first_dispatch} = PublicationAttemptStore.claim_dispatch(first_attempt)

    assert {:ok, {_succeeded, _published}} =
             PublicationAttemptStore.succeed(first_dispatch, message, "12345", completed_at())

    second =
      Repo.insert!(%MessageRecord{
        conversation_id: "conversation-1",
        persona_id: "observer",
        origin: :llm,
        content: "A second bounded confirmed fact.",
        inserted_at: ~U[2026-08-05 12:04:00.000000Z]
      })

    {second_plan, persona, settings} = plan(second)

    assert {:ok, second_attempt} =
             PublicationAttemptStore.start(
               second_plan,
               second,
               persona,
               settings,
               ~U[2026-08-05 12:05:00.000000Z]
             )

    assert {:ok, second_dispatch} = PublicationAttemptStore.claim_dispatch(second_attempt)

    assert PublicationAttemptStore.succeed(
             second_dispatch,
             second,
             "12345",
             ~U[2026-08-05 12:06:00.000000Z]
           ) == {:error, :publication_conflict}

    assert PublicationAttemptStore.fetch(second.id) == {:ok, second_dispatch}
    assert Repo.get!(MessageRecord, second.id) == second
  end

  test "rejects invalid success inputs before storage access", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)

    Repo.put_dynamic_repo(:missing_publication_attempt_repo)

    for discord_message_id <- [nil, "", "0", "012345", "message-1"] do
      assert PublicationAttemptStore.succeed(
               dispatching,
               message,
               discord_message_id,
               completed_at()
             ) == {:error, :invalid_publication_id}
    end

    assert PublicationAttemptStore.succeed(
             dispatching,
             %{message | id: message.id + 1},
             "12345",
             completed_at()
           ) == {:error, :publication_conflict}

    assert PublicationAttemptStore.succeed(
             dispatching,
             message,
             "12345",
             DateTime.add(started_at(), -1, :microsecond)
           ) == {:error, :invalid_datetime}
  end

  test "rolls back both success records after a valid trigger rewrite", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER rewrite_succeeded_attempt
      AFTER UPDATE OF status ON publication_attempts
      BEGIN
        UPDATE publication_attempts
        SET completed_at = '2026-08-05T12:03:01.000000Z'
        WHERE message_id = NEW.message_id;
      END
      """,
      [],
      log: false
    )

    try do
      assert PublicationAttemptStore.succeed(dispatching, message, "12345", completed_at()) ==
               {:error, :publication_attempt_conflict}

      assert PublicationAttemptStore.fetch(message.id) == {:ok, dispatching}
      assert Repo.get!(MessageRecord, message.id) == message
    after
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER rewrite_succeeded_attempt", [], log: false)
    end
  end

  test "rolls back both success records after a valid message rewrite", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER rewrite_succeeded_message
      AFTER UPDATE OF discord_message_id ON messages
      BEGIN
        UPDATE messages
        SET discord_message_id = '67890'
        WHERE id = NEW.id;
      END
      """,
      [],
      log: false
    )

    try do
      assert PublicationAttemptStore.succeed(dispatching, message, "12345", completed_at()) ==
               {:error, :publication_conflict}

      assert PublicationAttemptStore.fetch(message.id) == {:ok, dispatching}
      assert Repo.get!(MessageRecord, message.id) == message
    after
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER rewrite_succeeded_message", [], log: false)
    end
  end

  test "returns a generic success storage failure", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)

    Repo.put_dynamic_repo(:missing_publication_attempt_repo)

    assert PublicationAttemptStore.succeed(dispatching, message, "12345", completed_at()) ==
             {:error, :storage_unavailable}
  end

  test "does not overwrite a different terminal outcome", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {:ok, failed} =
             PublicationAttemptStore.fail(started, :unavailable, completed_at())

    assert PublicationAttemptStore.fail(started, :timeout, completed_at()) ==
             {:error, :publication_attempt_conflict}

    assert PublicationAttemptStore.mark_ambiguous(started, completed_at()) ==
             {:error, :publication_attempt_conflict}

    assert PublicationAttemptStore.fetch(message.id) == {:ok, failed}
  end

  test "rejects invalid terminal inputs before storage access", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    Repo.put_dynamic_repo(:missing_publication_attempt_repo)

    assert PublicationAttemptStore.fail(started, :interrupted, completed_at()) ==
             {:error, :invalid_external_error}

    assert PublicationAttemptStore.fail(
             started,
             :timeout,
             DateTime.add(started_at(), -1, :microsecond)
           ) == {:error, :invalid_datetime}

    assert PublicationAttemptStore.mark_ambiguous(%{started | status: :failed}, completed_at()) ==
             {:error, :invalid_publication_attempt_record}
  end

  test "fails closed when the durable attempt changed or became invalid", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert {1, nil} =
             Repo.update_all(PublicationAttemptRecord,
               set: [started_at: DateTime.add(started_at(), 1, :microsecond)]
             )

    assert PublicationAttemptStore.fail(started, :timeout, completed_at()) ==
             {:error, :publication_attempt_conflict}

    Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = ON", [], log: false)

    try do
      assert {1, nil} =
               Repo.update_all(PublicationAttemptRecord,
                 set: [status: :failed, completed_at: nil, error_class: nil]
               )
    after
      Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = OFF", [], log: false)
    end

    assert PublicationAttemptStore.fail(started, :timeout, completed_at()) ==
             {:error, :invalid_publication_attempt_record}

    Repo.delete_all(PublicationAttemptRecord)
  end

  test "returns a generic terminal storage failure", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, started} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    Repo.put_dynamic_repo(:missing_publication_attempt_repo)

    assert PublicationAttemptStore.fail(started, :timeout, completed_at()) ==
             {:error, :storage_unavailable}

    assert PublicationAttemptStore.mark_ambiguous(started, completed_at()) ==
             {:error, :storage_unavailable}
  end

  test "rejects a different retry for an existing attempt", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, first} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    assert PublicationAttemptStore.start(
             plan,
             message,
             persona,
             settings,
             DateTime.add(started_at(), 1, :microsecond)
           ) == {:error, :publication_attempt_conflict}

    assert PublicationAttemptStore.fetch(message.id) == {:ok, first}
  end

  test "rejects a plan whose durable message changed after validation", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {1, nil} =
             Repo.update_all(
               MessageRecord,
               set: [discord_message_id: "12345"]
             )

    assert PublicationAttemptStore.start(plan, message, persona, settings, started_at()) ==
             {:error, :publication_conflict}

    assert Repo.aggregate(PublicationAttemptRecord, :count) == 0
  end

  test "rejects a still-unpublished durable content rewrite", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {1, nil} = Repo.update_all(MessageRecord, set: [content: "Changed confirmed fact."])

    assert PublicationAttemptStore.start(plan, message, persona, settings, started_at()) ==
             {:error, :publication_conflict}

    assert Repo.aggregate(PublicationAttemptRecord, :count) == 0
  end

  test "fails closed on an invalid durable attempt", %{message: message} do
    {plan, persona, settings} = plan(message)

    assert {:ok, _attempt} =
             PublicationAttemptStore.start(plan, message, persona, settings, started_at())

    Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = ON", [], log: false)

    try do
      assert {1, nil} = Repo.update_all(PublicationAttemptRecord, set: [status: :failed])
    after
      Ecto.Adapters.SQL.query!(Repo, "PRAGMA ignore_check_constraints = OFF", [], log: false)
    end

    assert PublicationAttemptStore.fetch(message.id) ==
             {:error, :invalid_publication_attempt_record}

    assert PublicationAttemptStore.start(plan, message, persona, settings, started_at()) ==
             {:error, :invalid_publication_attempt_record}

    Repo.delete_all(PublicationAttemptRecord)
  end

  test "rolls back a valid insert-time rewrite", %{message: message} do
    {plan, persona, settings} = plan(message)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER rewrite_publication_attempt
      AFTER INSERT ON publication_attempts
      BEGIN
        UPDATE publication_attempts
        SET started_at = '2026-08-05T12:02:01.000000Z'
        WHERE message_id = NEW.message_id;
      END
      """,
      [],
      log: false
    )

    try do
      assert PublicationAttemptStore.start(plan, message, persona, settings, started_at()) ==
               {:error, :publication_attempt_conflict}

      assert Repo.aggregate(PublicationAttemptRecord, :count) == 0
    after
      Ecto.Adapters.SQL.query!(
        Repo,
        "DROP TRIGGER rewrite_publication_attempt",
        [],
        log: false
      )
    end
  end

  test "rejects invalid plan and timing before storage access", %{message: message} do
    {plan, persona, settings} = plan(message)
    Repo.put_dynamic_repo(:missing_publication_attempt_repo)

    assert PublicationAttemptStore.start(nil, message, persona, settings, started_at()) ==
             {:error, :invalid_publication_plan}

    assert PublicationAttemptStore.start(
             plan,
             message,
             persona,
             settings,
             DateTime.add(message.inserted_at, -1, :microsecond)
           ) == {:error, :invalid_datetime}

    for id <- [nil, 0, 1.0, 9_223_372_036_854_775_808] do
      assert PublicationAttemptStore.fetch(id) == {:error, :invalid_message_id}
    end
  end

  test "returns generic storage failures", %{message: message} do
    {plan, persona, settings} = plan(message)
    Repo.put_dynamic_repo(:missing_publication_attempt_repo)

    assert PublicationAttemptStore.fetch(message.id) == {:error, :storage_unavailable}

    assert PublicationAttemptStore.start(plan, message, persona, settings, started_at()) ==
             {:error, :storage_unavailable}
  end

  defp plan(message) do
    persona = persona()
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(message, persona, settings)
    {plan, persona, settings}
  end

  defp started_at, do: ~U[2026-08-05 12:02:00.000000Z]
  defp completed_at, do: ~U[2026-08-05 12:03:00.000000Z]

  defp persona do
    %Persona{
      id: "observer",
      display_name: "Observer",
      avatar: nil,
      prompt: "Use only supplied facts.",
      enabled: true,
      interests: %{},
      behavior: %{},
      relationships: %{},
      metadata: %{}
    }
  end

  defp settings do
    %WebhookSettings{
      url: Enum.join(["https://", "discord", ".", "com", "/api/webhooks/1/fake-token"])
    }
  end
end

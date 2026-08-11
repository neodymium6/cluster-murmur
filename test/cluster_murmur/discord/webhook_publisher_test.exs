defmodule ClusterMurmur.Discord.WebhookPublisherTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Discord.{
    PublicationPlanner,
    WebhookPublisher,
    WebhookRequest,
    WebhookResponse,
    WebhookSettings
  }

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    EventRecord,
    MessageRecord,
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
    migrations = [
      {@event_version, CreateEvents},
      {@conversation_version, CreateConversations},
      {@message_version, CreateMessages},
      {@attempt_version, CreatePublicationAttempts},
      {@dispatching_version, AddPublicationAttemptDispatching}
    ]

    for {version, migration} <- migrations do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- Enum.reverse(migrations) do
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

    :ok
  end

  test "claims once and invokes the fixed transport at most once" do
    {started, plan, record, persona, settings} = scenario(1)
    parent = self()

    transport = fn request ->
      send(parent, {:request, request})
      {:ok, response(200, ~s({"id":"12345"}))}
    end

    assert {:ok, "12345", dispatching} =
             publish(started, plan, record, persona, settings, transport)

    assert dispatching.status == :dispatching
    assert_receive {:request, %WebhookRequest{} = request}
    assert WebhookRequest.validate(request, plan, record, persona, settings) == :ok

    assert publish(started, plan, record, persona, settings, transport) ==
             {:error, :publication_attempt_conflict}

    refute_receive {:request, _request}
  end

  test "returns only proven HTTP rejections as known failures" do
    for {index, status, error_class} <- [
          {1, 400, :invalid_request},
          {2, 401, :authentication_failed},
          {3, 403, :authentication_failed},
          {4, 404, :authentication_failed},
          {5, 429, :rate_limited}
        ] do
      {started, plan, record, persona, settings} = scenario(index)
      transport = fn _request -> {:ok, response(status, "Private remote diagnostic")} end

      assert {:failed, ^error_class, dispatching} =
               publish(started, plan, record, persona, settings, transport)

      assert dispatching.status == :dispatching
    end
  end

  test "marks every response with a possibly accepted effect ambiguous" do
    oversized = String.duplicate("x", WebhookRequest.max_response_bytes() + 1)

    for {index, status, body} <- [
          {1, 200, "malformed"},
          {2, 200, oversized},
          {3, 201, ~s({"id":"12345"})},
          {4, 408, "timeout"},
          {5, 500, "unavailable"},
          {6, 504, "gateway timeout"}
        ] do
      {started, plan, record, persona, settings} = scenario(index)
      transport = fn _request -> {:ok, response(status, body)} end

      assert {:ambiguous, :interrupted, dispatching} =
               publish(started, plan, record, persona, settings, transport)

      assert dispatching.status == :dispatching
    end
  end

  test "distinguishes proven pre-send failures from unknown transport effects" do
    for {index, error_class} <- [{1, :invalid_request}, {2, :timeout}, {3, :unavailable}] do
      {started, plan, record, persona, settings} = scenario(index)
      transport = fn _request -> {:error, :not_sent, error_class} end

      assert {:failed, ^error_class, dispatching} =
               publish(started, plan, record, persona, settings, transport)

      assert dispatching.status == :dispatching
    end

    for {index, transport} <- [
          {4, fn _request -> {:error, :outcome_unknown} end},
          {5, fn _request -> nil end},
          {6, fn _request -> raise "private failure" end},
          {7, fn _request -> throw(:private_failure) end},
          {8, fn _request -> exit(:private_failure) end}
        ] do
      {started, plan, record, persona, settings} = scenario(index)

      assert {:ambiguous, :interrupted, dispatching} =
               publish(started, plan, record, persona, settings, transport)

      assert dispatching.status == :dispatching
    end
  end

  test "rejects invalid boundaries before transport or dispatch claim" do
    {started, plan, record, persona, settings} = scenario(1)
    parent = self()

    transport = fn _request ->
      send(parent, :transport_called)
      {:error, :outcome_unknown}
    end

    assert publish(
             started,
             plan,
             %{record | content: "Changed fact."},
             persona,
             settings,
             transport
           ) ==
             {:error, :invalid_request}

    assert publish(
             started,
             plan,
             record,
             %{persona | display_name: "Changed"},
             settings,
             transport
           ) ==
             {:error, :invalid_request}

    assert publish(started, plan, record, persona, other_settings(), transport) ==
             {:error, :invalid_request}

    assert publish(started, plan, record, persona, settings, nil) ==
             {:error, :invalid_request}

    assert PublicationAttemptStore.fetch(record.id) == {:ok, started}
    refute_receive :transport_called
  end

  test "rejects reused or forged attempt capabilities before transport" do
    {started, plan, record, persona, settings} = scenario(1)
    assert {:ok, dispatching} = PublicationAttemptStore.claim_dispatch(started)
    parent = self()

    transport = fn _request ->
      send(parent, :transport_called)
      {:error, :outcome_unknown}
    end

    assert publish(started, plan, record, persona, settings, transport) ==
             {:error, :publication_attempt_conflict}

    assert publish(dispatching, plan, record, persona, settings, transport) ==
             {:error, :invalid_publication_attempt_record}

    refute_receive :transport_called
  end

  test "returns generic claim storage failure without transport values" do
    {started, plan, record, persona, settings} = scenario(1)
    transport = fn _request -> raise "must not run" end
    Repo.put_dynamic_repo(:missing_webhook_publisher_repo)

    result = publish(started, plan, record, persona, settings, transport)
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "must not run"
  end

  defp publish(started, plan, record, persona, settings, transport),
    do: WebhookPublisher.publish(started, plan, record, persona, settings, transport)

  defp scenario(index) do
    inserted_at = DateTime.add(~U[2026-08-05 12:01:00.000000Z], index * 10, :second)

    record =
      Repo.insert!(%MessageRecord{
        conversation_id: "conversation-1",
        persona_id: "observer",
        origin: :llm,
        content: "A bounded confirmed fact #{index}.",
        inserted_at: inserted_at
      })

    persona = persona()
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(record, persona, settings)

    assert {:ok, started} =
             PublicationAttemptStore.start(
               plan,
               record,
               persona,
               settings,
               DateTime.add(inserted_at, 1, :second)
             )

    {started, plan, record, persona, settings}
  end

  defp response(status, body), do: %WebhookResponse{status: status, body: body}

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

  defp settings, do: %WebhookSettings{url: webhook_url("1", "fake-token")}

  defp other_settings,
    do: %WebhookSettings{url: webhook_url("2", "other-fake-token")}

  defp webhook_url(id, token),
    do: Enum.join(["https://", "discord", ".", "com", "/api/webhooks/", id, "/", token])
end

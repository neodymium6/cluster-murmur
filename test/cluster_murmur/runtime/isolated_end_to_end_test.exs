defmodule ClusterMurmur.Runtime.IsolatedEndToEndTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.{ExternalIngestion, StateTracking}

  alias ClusterMurmur.Discord.{
    WebhookPublisher,
    WebhookRequest,
    WebhookResponse
  }

  alias ClusterMurmur.Generation.{
    OpenAICompatibleHTTPTransport,
    OpenAICompatibleProvider,
    ProviderSettings
  }

  alias ClusterMurmur.Observers.{
    Client,
    MCPClient,
    MCPHTTPTransport,
    MCPSettings
  }

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationStore,
    EntityStateRecord,
    EventDispatch,
    EventRecord,
    EventTriggerConversationActionStore,
    MessageRecord,
    MessageStore,
    PersonaCooldownRecord,
    PersonaCooldownStore,
    PublicationAttemptRecord,
    PublicationAttemptStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Ingestion.{BearerAuthentication, HTTPSettings}

  alias ClusterMurmur.Runtime.{
    EventDispatchCycle,
    ExternalIngestionServer,
    PollStarterCycle,
    Recovery
  }

  alias ClusterMurmur.Runtime.EventDispatchCycle.Context, as: EventDispatchContext
  alias ClusterMurmur.Runtime.ExternalIngestionServer.Options, as: IngestionServerOptions
  alias ClusterMurmur.Runtime.PollStarterCycle.Context
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, SharedInput}

  alias ClusterMurmur.Repo.Migrations.{
    AddPublicationAttemptDispatching,
    CreateConversations,
    CreateEntityStates,
    CreateEventDedupeMarkers,
    CreateEventDispatches,
    CreateEvents,
    CreateMessages,
    CreatePersonaCooldowns,
    CreatePublicationAttempts,
    CreateTriggerExecutions
  }

  @migrations [
    {20_260_804_180_500, CreateEvents},
    {20_260_804_200_000, CreateTriggerExecutions},
    {20_260_805_200_000, CreateConversations},
    {20_260_805_220_000, CreateMessages},
    {20_260_805_224_000, CreatePersonaCooldowns},
    {20_260_805_225_000, CreateEntityStates},
    {20_260_805_230_000, CreatePublicationAttempts},
    {20_260_805_231_000, AddPublicationAttemptDispatching},
    {20_260_808_150_000, CreateEventDispatches},
    {20_260_809_020_000, CreateEventDedupeMarkers}
  ]

  defmodule NoRandomness do
    @moduledoc false
    def weighted_choice(_choices), do: raise("one candidate must not sample")
    def uniform, do: raise("zero reply probability must not sample")
  end

  defmodule FixedClock do
    @moduledoc false
    def utc_now, do: ~U[2026-08-07 02:00:00.000000Z]
  end

  setup_all do
    for {version, migration} <- @migrations do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- Enum.reverse(@migrations) do
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
    for table <- [
          "publication_attempts",
          "messages",
          "persona_cooldowns",
          "conversations",
          "trigger_executions",
          "event_dedupe_markers",
          "entity_states",
          "event_dispatches",
          "events"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}", [], log: false)
    end

    :ok
  end

  test "runs isolated HTTP inputs through durable publication and recovery once" do
    {observer_endpoint, observer_task} =
      serve_json([
        mcp_targets(),
        mcp_health("2026-08-07T01:59:59.000000Z"),
        mcp_targets(),
        mcp_health("2026-08-07T02:00:02.000000Z")
      ])

    {provider_base_url, provider_task} = serve_json([provider_response()])
    discord_destination = start_supervised!({Agent, fn -> [] end})

    configuration =
      RuntimeFixture.configuration()
      |> Map.put(:state_tracking, %StateTracking{
        failures_required: 1,
        successes_required: 1,
        overrides: %{}
      })

    observer_settings = %MCPSettings{
      endpoint: observer_endpoint <> "/mcp",
      bearer_token: "clearly-fake-observer-token"
    }

    observer_transport = fn request -> MCPHTTPTransport.execute(request, observer_settings) end
    assert {:ok, observer_client} = Client.new(MCPClient, observer_transport)

    provider_settings = %ProviderSettings{
      provider: :openai_compatible,
      base_url: provider_base_url <> "/v1",
      model: "example-model",
      api_key: "clearly-fake-api-key",
      timeout_ms: 20_000,
      max_output_tokens: 300
    }

    generation_transport = fn request ->
      OpenAICompatibleHTTPTransport.execute(request, provider_settings)
    end

    publication_transport = fn %WebhookRequest{} = request ->
      Agent.update(discord_destination, &[request | &1])
      {:ok, %WebhookResponse{status: 200, body: ~s({"id":"12345"})}}
    end

    context = %Context{
      shared_input: %SharedInput{
        configuration: configuration,
        cooldowns: %{},
        provider_settings: provider_settings,
        webhook_settings: RuntimeFixture.webhook_settings(),
        generation_transport: generation_transport,
        publication_transport: publication_transport
      },
      adapters: adapters()
    }

    assert {:ok, first} =
             PollStarterCycle.run(
               observer_client,
               configuration,
               ~U[2026-08-07 02:00:00.000000Z],
               context
             )

    assert first.event_count == 1
    assert first.match_count == 1

    assert first.dispatched_count == 1
    assert first.dispatch_failure_count == 0

    assert {:ok, recovery} =
             Recovery.run(
               ~U[2026-08-07 02:00:01.000000Z],
               ~U[2026-08-07 02:00:02.000000Z]
             )

    assert recovery.execution_count == 0
    assert recovery.conversation_count == 0
    assert recovery.publication_count == 0
    assert recovery.failure_count == 0

    assert {:ok, resumed} =
             PollStarterCycle.run(
               observer_client,
               configuration,
               ~U[2026-08-07 02:00:03.000000Z],
               context
             )

    assert resumed.ingested_count == 1
    assert resumed.event_count == 0
    assert resumed.match_count == 0
    assert resumed.dispatched_count == 0

    observer_requests = Task.await(observer_task)
    provider_requests = Task.await(provider_task)
    publications = Agent.get(discord_destination, &Enum.reverse/1)

    assert length(observer_requests) == 4
    assert Enum.count(observer_requests, &String.contains?(&1, "observer_list_targets")) == 2

    assert Enum.count(observer_requests, &String.contains?(&1, "kubernetes_get_cluster_health")) ==
             2

    assert [provider_request] = provider_requests
    assert provider_request =~ "POST /v1/chat/completions HTTP/1.1"
    assert [%WebhookRequest{json: %{"content" => "A bounded confirmed fact."}}] = publications

    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(ConversationRecord, :count) == 1
    assert Repo.aggregate(MessageRecord, :count) == 1
    assert Repo.aggregate(PublicationAttemptRecord, :count) == 1

    assert %ConversationRecord{status: :completed, turn_count: 1, llm_call_count: 1} =
             Repo.one!(ConversationRecord)

    assert %MessageRecord{
             content: "A bounded confirmed fact.",
             discord_message_id: "12345"
           } = Repo.one!(MessageRecord)

    assert %PublicationAttemptRecord{status: :succeeded} = Repo.one!(PublicationAttemptRecord)

    assert %EntityStateRecord{
             current_state: :unhealthy,
             last_observed_at: ~U[2026-08-07 02:00:02.000000Z]
           } = Repo.one!(EntityStateRecord)

    refute inspect(first) =~ "workloads-not-ready"
    refute inspect(first) =~ "A bounded confirmed fact."
  end

  test "ingests HTTP events through durable dispatch, cooldown, and publication once" do
    configuration = external_configuration()
    publication_destination = start_supervised!({Agent, fn -> [] end})
    token = "clearly-fake-ingestion-token-123456"
    port = available_port()
    {:ok, token_digest} = BearerAuthentication.digest(token)

    options = %IngestionServerOptions{
      settings: %HTTPSettings{port: port, token_digest: token_digest},
      configuration: configuration.external_ingestion,
      clock: FixedClock,
      commit: &ClusterMurmur.Persistence.ExternalEventCommitStore.commit/3
    }

    start_supervised!({ExternalIngestionServer, options})

    publication_transport = fn %WebhookRequest{} = request ->
      Agent.update(publication_destination, &[request | &1])
      {:ok, %WebhookResponse{status: 200, body: ~s({"id":"12345"})}}
    end

    context = %EventDispatchContext{
      shared_input: %SharedInput{
        configuration: configuration,
        cooldowns: %{},
        provider_settings: RuntimeFixture.provider_settings(),
        webhook_settings: RuntimeFixture.webhook_settings(),
        generation_transport: fn _request -> {:ok, "A bounded external fact."} end,
        publication_transport: publication_transport
      },
      adapters: adapters(RuntimeFixture.FakeProvider)
    }

    assert post_event(port, token, external_event_body("retry-identity")) =~
             "HTTP/1.1 202 Accepted\r\n"

    assert post_event(port, token, external_event_body("retry-identity")) =~
             "HTTP/1.1 202 Accepted\r\n"

    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1

    assert {:ok, first} =
             EventDispatchCycle.run(
               configuration,
               ~U[2026-08-07 02:00:01.000000Z],
               context
             )

    assert first.candidate_count == 1
    assert first.planned_match_count == 1
    assert first.dispatched_count == 1
    assert first.completed_count == 1

    assert %PersonaCooldownRecord{
             persona_id: "caretaker",
             last_spoken_at: ~U[2026-08-07 02:00:01.000000Z],
             cooldown_until: ~U[2026-08-07 02:01:01.000000Z]
           } = Repo.one!(PersonaCooldownRecord)

    assert post_event(port, token, external_event_body("retry-identity")) =~
             "HTTP/1.1 202 Accepted\r\n"

    assert post_event(port, token, external_event_body("cooldown-identity")) =~
             "HTTP/1.1 202 Accepted\r\n"

    assert {:ok, cooldown} =
             EventDispatchCycle.run(
               configuration,
               ~U[2026-08-07 02:00:02.000000Z],
               context
             )

    assert cooldown.candidate_count == 1
    assert cooldown.planned_match_count == 1
    assert cooldown.dispatched_count == 0
    assert cooldown.skipped_count == 1
    assert cooldown.dedupe_suppressed_count == 0
    assert cooldown.completed_count == 1

    assert Repo.aggregate(EventRecord, :count) == 2
    assert Repo.aggregate(EventDispatch, :count) == 2
    assert Repo.aggregate(ConversationRecord, :count) == 1
    assert Repo.aggregate(MessageRecord, :count) == 1
    assert Repo.aggregate(PublicationAttemptRecord, :count) == 1

    assert [%WebhookRequest{json: %{"content" => "A bounded external fact."}}] =
             Agent.get(publication_destination, &Enum.reverse/1)

    assert %ConversationRecord{status: :completed, turn_count: 1, llm_call_count: 1} =
             Repo.one!(ConversationRecord)

    assert %MessageRecord{content: "A bounded external fact.", discord_message_id: "12345"} =
             Repo.one!(MessageRecord)
  end

  defp adapters(provider \\ OpenAICompatibleProvider) do
    %Adapters{
      conversation_action_store: EventTriggerConversationActionStore,
      provider: provider,
      message_store: MessageStore,
      publication_start_store: PublicationAttemptStore,
      publisher: WebhookPublisher,
      publication_terminal_store: PublicationAttemptStore,
      cooldown_store: PersonaCooldownStore,
      conversation_store: ConversationStore,
      starter_random: NoRandomness,
      reply_random: NoRandomness
    }
  end

  defp external_configuration do
    {:ok, external_ingestion} =
      ExternalIngestion.parse(%{
        "sources" => %{
          "alert-adapter" => %{
            "event_types" => ["observation.failed"],
            "groups" => ["operations"],
            "subjects" => ["example-target"],
            "fact_keys" => ["detail"],
            "label_keys" => ["site"]
          }
        }
      })

    %{RuntimeFixture.configuration() | external_ingestion: external_ingestion}
  end

  defp external_event_body(idempotency_key) do
    encode_json(%{
      "idempotency_key" => idempotency_key,
      "type" => "observation.failed",
      "source" => "alert-adapter",
      "subject" => "example-target",
      "group" => "operations",
      "severity" => "warning",
      "occurred_at" => "2026-08-07T01:59:59.000000Z",
      "facts" => %{"detail" => "bounded external detail"},
      "labels" => %{"site" => "example-site"}
    })
  end

  defp post_event(port, token, body) do
    request =
      "POST /v1/events HTTP/1.1\r\n" <>
        "host: example.invalid\r\n" <>
        "authorization: Bearer #{token}\r\n" <>
        "content-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\n\r\n" <> body

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    :ok = :gen_tcp.send(socket, request)
    response = receive_response(socket, <<>>)
    :gen_tcp.close(socket)
    response
  end

  defp receive_response(socket, response) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> receive_response(socket, response <> chunk)
      {:error, :closed} -> response
    end
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp serve_json(bodies) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        requests =
          Enum.map(bodies, fn body ->
            {:ok, socket} = :gen_tcp.accept(listener)
            {:ok, request} = receive_request(socket)
            :ok = send_json(socket, body)
            :ok = :gen_tcp.close(socket)
            request
          end)

        :ok = :gen_tcp.close(listener)
        requests
      end)

    {"http://127.0.0.1:#{port}", task}
  end

  defp receive_request(socket, received \\ <<>>) do
    case :binary.split(received, "\r\n\r\n") do
      [headers, body] -> receive_request_body(socket, headers, body)
      [_incomplete] -> receive_more(socket, received)
    end
  end

  defp receive_more(socket, received) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> receive_request(socket, received <> data)
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_request_body(socket, headers, body) do
    with [length] <-
           Regex.run(~r/\r\ncontent-length: ([0-9]+)\r\n/i, "\r\n" <> headers <> "\r\n",
             capture: :all_but_first
           ),
         {length, ""} <- Integer.parse(length),
         {:ok, body} <- receive_body(socket, body, length) do
      {:ok, headers <> "\r\n\r\n" <> body}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp receive_body(_socket, body, length) when byte_size(body) == length,
    do: {:ok, body}

  defp receive_body(socket, body, length) when byte_size(body) < length do
    case :gen_tcp.recv(socket, length - byte_size(body), 5_000) do
      {:ok, data} -> receive_body(socket, body <> data, length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_body(_socket, _body, _length), do: {:error, :invalid_request}

  defp send_json(socket, body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end

  defp mcp_targets do
    mcp_envelope(%{
      "targets" => [
        %{
          "id" => "example-target",
          "kind" => "kubernetes",
          "capabilities" => ["kubernetes.cluster-health"]
        }
      ]
    })
  end

  defp mcp_health(observed_at) do
    mcp_envelope(%{
      "target" => "example-target",
      "observedAt" => observed_at,
      "status" => "degraded",
      "nodes" => %{"total" => 1, "ready" => 1},
      "workloads" => %{"total" => 1, "ready" => 0, "unhealthy" => 1},
      "warnings" => [%{"code" => "workloads-not-ready", "count" => 1}],
      "partial" => false
    })
  end

  defp mcp_envelope(structured_content) do
    encode_json(%{
      "id" => 1,
      "jsonrpc" => "2.0",
      "result" => %{
        "content" => [],
        "isError" => false,
        "resultType" => "complete",
        "structuredContent" => structured_content
      }
    })
  end

  defp provider_response do
    encode_json(%{
      "choices" => [
        %{
          "message" => %{
            "content" => "A bounded confirmed fact.",
            "role" => "assistant"
          }
        }
      ]
    })
  end

  defp encode_json(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end

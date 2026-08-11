defmodule ClusterMurmur.Runtime.IsolatedEndToEndTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.StateTracking

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
    EventRecord,
    EventTriggerConversationActionStore,
    MessageRecord,
    MessageStore,
    PersonaCooldownStore,
    PublicationAttemptRecord,
    PublicationAttemptStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Runtime.{PollStarterCycle, Recovery}
  alias ClusterMurmur.Runtime.PollStarterCycle.Context
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, SharedInput}

  alias ClusterMurmur.Repo.Migrations.{
    AddPublicationAttemptDispatching,
    CreateConversations,
    CreateEntityStates,
    CreateEventDedupeMarkers,
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
    {20_260_809_020_000, CreateEventDedupeMarkers}
  ]

  defmodule NoRandomness do
    @moduledoc false
    def weighted_choice(_choices), do: raise("one candidate must not sample")
    def uniform, do: raise("zero reply probability must not sample")
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

  defp adapters do
    %Adapters{
      conversation_action_store: EventTriggerConversationActionStore,
      provider: OpenAICompatibleProvider,
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

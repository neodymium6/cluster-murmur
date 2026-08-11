defmodule ClusterMurmur.Runtime.PollStarterCycleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.Observations.{IngestionPlanner, Observation}
  alias ClusterMurmur.Observers.Client
  alias ClusterMurmur.Persistence.PersonaCooldownRecord
  alias ClusterMurmur.Runtime.PollStarterCycle
  alias ClusterMurmur.Runtime.PollStarterCycle.Result
  alias ClusterMurmur.Runtime.ResponderTurnSchedule
  alias ClusterMurmur.Runtime.ResponderTurnSchedule.Step
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Runtime.PollStarterCycle.{Context, ConversationRuntime}
  alias ClusterMurmur.Runtime.ResponderTurnCycle.Adapters, as: ResponderAdapters

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.Adapters,
    as: ConversationAdapters

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer,
    as: ConversationConsumer

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.Context,
    as: ConversationConsumerContext

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, SharedInput}

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer,
    as: StarterConsumer

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Context,
    as: StarterConsumerContext

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  defmodule FakeObserver do
    def list_targets(:process_dictionary) do
      record(:list_targets)
      Process.get({__MODULE__, :targets}, {:ok, []})
    end

    def observe_target(:process_dictionary, target_id) do
      record({:observe_target, target_id})
      Process.get({__MODULE__, :observation})
    end

    defp record(call) do
      Process.put({__MODULE__, :calls}, Process.get({__MODULE__, :calls}, []) ++ [call])
    end
  end

  defmodule FakeIngestionStore do
    def ingest(observation, policy), do: IngestionPlanner.plan(nil, observation, policy)
  end

  defmodule AdaptersStub do
    def consume(_plan), do: :unused

    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def append_reserved(_conversation, _message), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused

    def fetch(persona_id) do
      record({:fetch_cooldown, persona_id})
      Process.get({__MODULE__, :cooldown, persona_id}, {:ok, nil})
    end

    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def complete(_conversation_id, _completed_at), do: :unused
    def wait(_conversation), do: :unused
    def claim_generation(_conversation, _persona_id), do: :unused
    def consume_generation(_conversation, _persona_id), do: :unused
    def confirm_completed(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused

    defp record(call) do
      Process.put({__MODULE__, :calls}, Process.get({__MODULE__, :calls}, []) ++ [call])
    end
  end

  setup do
    Process.put({FakeObserver, :calls}, [])
    Process.put({AdaptersStub, :calls}, [])
    Process.put({FakeObserver, :targets}, {:ok, [%{id: "example-target"}]})

    Process.put(
      {FakeObserver, :observation},
      {:ok,
       %Observation{
         source: "example-observer",
         subject: "example-target",
         state: :unhealthy,
         observed_at: ~U[2026-08-07 01:59:59.000000Z],
         facts: %{"detail" => "private fact"},
         labels: %{"category" => "monitoring"}
       }}
    )

    :ok
  end

  test "composes one bounded poll with a no-event starter dispatch" do
    configuration = RuntimeFixture.configuration()

    configuration = %{
      configuration
      | state_tracking: %StateTracking{failures_required: 2, successes_required: 2}
    }

    assert {:ok, client} = Client.new(FakeObserver, :process_dictionary)

    assert {:ok, %Result{} = result} =
             PollStarterCycle.run(
               client,
               configuration,
               @executed_at,
               context(configuration),
               FakeIngestionStore
             )

    assert result.target_count == 1
    assert result.ingested_count == 1
    assert result.event_count == 0
    assert result.poll_failure_count == 0
    assert result.match_count == 0
    assert result.dispatched_count == 0
    assert result.skipped_count == 0
    assert result.dispatch_failure_count == 0

    assert Process.get({FakeObserver, :calls}) == [
             :list_targets,
             {:observe_target, "example-target"}
           ]

    assert Process.get({AdaptersStub, :calls}) == [{:fetch_cooldown, "caretaker"}]

    refute inspect(result) =~ "example-target"
    refute inspect(result) =~ "private fact"
  end

  test "fails before observation when the current cooldown snapshot cannot load" do
    configuration = RuntimeFixture.configuration()
    assert {:ok, client} = Client.new(FakeObserver, :process_dictionary)
    Process.put({AdaptersStub, :cooldown, "caretaker"}, {:error, :storage_unavailable})

    assert PollStarterCycle.run(
             client,
             configuration,
             @executed_at,
             context(configuration),
             FakeIngestionStore
           ) == {:error, :poll_failed}

    assert Process.get({AdaptersStub, :calls}) == [{:fetch_cooldown, "caretaker"}]
    assert Process.get({FakeObserver, :calls}) == []
  end

  test "applies changed fetched cooldowns on every starter and conversation cycle" do
    assert {:ok, client} = Client.new(FakeObserver, :process_dictionary)

    for {configuration, build_context, consumer} <- [
          {RuntimeFixture.configuration(), &context/1, StarterConsumer},
          {RuntimeFixture.responder_configuration(),
           &conversation_context(&1, responder_schedule()), ConversationConsumer}
        ] do
      configuration = immediate_state_changes(configuration)
      persona_ids = configuration.personas.personas |> Map.keys() |> Enum.sort()
      fetch_calls = Enum.map(persona_ids, &{:fetch_cooldown, &1})

      Enum.each(persona_ids, &Process.delete({AdaptersStub, :cooldown, &1}))
      Process.put({AdaptersStub, :calls}, [])

      {result, consumer_context} =
        capture_consumer_context(consumer, fn ->
          PollStarterCycle.run(
            client,
            configuration,
            @executed_at,
            build_context.(configuration),
            FakeIngestionStore
          )
        end)

      assert {:ok, %Result{event_count: 1, match_count: 1}} = result
      assert consumer_cooldowns(consumer_context) == %{}
      assert Process.get({AdaptersStub, :calls}) == fetch_calls

      refreshed_cooldowns =
        Map.new(persona_ids, fn persona_id ->
          record = cooldown(persona_id, @executed_at)
          Process.put({AdaptersStub, :cooldown, persona_id}, {:ok, record})
          {persona_id, record}
        end)

      Process.put({AdaptersStub, :calls}, [])

      {result, consumer_context} =
        capture_consumer_context(consumer, fn ->
          PollStarterCycle.run(
            client,
            configuration,
            @executed_at,
            build_context.(configuration),
            FakeIngestionStore
          )
        end)

      assert {:ok, %Result{event_count: 1, match_count: 1}} = result
      assert consumer_cooldowns(consumer_context) == refreshed_cooldowns
      assert Process.get({AdaptersStub, :calls}) == fetch_calls
    end
  end

  test "rejects invalid configuration before observing and collapses observer failures" do
    configuration = RuntimeFixture.configuration()
    assert {:ok, client} = Client.new(FakeObserver, :process_dictionary)
    context = context(configuration)

    assert PollStarterCycle.run(
             client,
             %{configuration | version: 1.0},
             @executed_at,
             context,
             FakeIngestionStore
           ) == {:error, :invalid_poll_starter_cycle}

    assert Process.get({FakeObserver, :calls}) == []

    Process.put({FakeObserver, :targets}, {:error, :unavailable})

    assert PollStarterCycle.run(
             client,
             configuration,
             @executed_at,
             context,
             FakeIngestionStore
           ) == {:error, :poll_failed}

    refute inspect(PollStarterCycle.run(client, nil, @executed_at, context, FakeIngestionStore)) =~
             "private"
  end

  test "validates an explicit conversation runtime before observing" do
    configuration = RuntimeFixture.responder_configuration()
    assert {:ok, client} = Client.new(FakeObserver, :process_dictionary)
    context = conversation_context(configuration, responder_schedule())

    assert PollStarterCycle.validate_runtime(configuration, context) == :ok

    invalid_schedule = %ResponderTurnSchedule{
      steps: [
        %{hd(responder_schedule().steps) | generation_transport: :invalid}
      ]
    }

    invalid = %{
      context
      | conversation_runtime: %{context.conversation_runtime | schedule: invalid_schedule}
    }

    assert PollStarterCycle.run(
             client,
             configuration,
             @executed_at,
             invalid,
             FakeIngestionStore
           ) == {:error, :invalid_poll_starter_cycle}

    assert Process.get({FakeObserver, :calls}) == []
  end

  defp adapters do
    %Adapters{
      conversation_action_store: AdaptersStub,
      provider: AdaptersStub,
      message_store: AdaptersStub,
      publication_start_store: AdaptersStub,
      publisher: AdaptersStub,
      publication_terminal_store: AdaptersStub,
      cooldown_store: AdaptersStub,
      conversation_store: AdaptersStub,
      starter_random: AdaptersStub,
      reply_random: AdaptersStub
    }
  end

  defp context(configuration) do
    %Context{
      shared_input: %SharedInput{
        configuration: configuration,
        cooldowns: %{},
        provider_settings: RuntimeFixture.provider_settings(),
        webhook_settings: RuntimeFixture.webhook_settings(),
        generation_transport: fn _request -> :unused end,
        publication_transport: fn _request -> :unused end
      },
      adapters: adapters()
    }
  end

  defp conversation_context(configuration, schedule) do
    starter_adapters = adapters()

    %Context{
      shared_input: shared_input(configuration),
      adapters: starter_adapters,
      conversation_runtime: %ConversationRuntime{
        schedule: schedule,
        adapters: %ConversationAdapters{
          starter: starter_adapters,
          responder: %ResponderAdapters{
            random: AdaptersStub,
            conversation_store: AdaptersStub,
            provider: AdaptersStub,
            message_store: AdaptersStub,
            publication_start_store: AdaptersStub,
            publisher: AdaptersStub,
            publication_terminal_store: AdaptersStub,
            cooldown_store: AdaptersStub
          }
        }
      }
    }
  end

  defp responder_schedule do
    %ResponderTurnSchedule{
      steps: [
        %Step{
          planned_after_ms: 0,
          generated_after_ms: 1_000,
          publication_started_after_ms: 2_000,
          publication_completed_after_ms: 3_000,
          generation_transport: fn _request -> :unused end,
          publication_transport: fn _request -> :unused end
        }
      ]
    }
  end

  defp shared_input(configuration) do
    %SharedInput{
      configuration: configuration,
      cooldowns: %{},
      provider_settings: RuntimeFixture.provider_settings(),
      webhook_settings: RuntimeFixture.webhook_settings(),
      generation_transport: fn _request -> :unused end,
      publication_transport: fn _request -> :unused end
    }
  end

  defp immediate_state_changes(configuration) do
    %{
      configuration
      | state_tracking: %StateTracking{failures_required: 1, successes_required: 1}
    }
  end

  defp capture_consumer_context(consumer, run_cycle) do
    owner = self()
    trace_ref = make_ref()
    tracer = spawn(fn -> forward_traces(owner, trace_ref) end)

    Code.ensure_loaded!(consumer)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern({consumer, :preflight, 4}, true, [])

    try do
      result = run_cycle.()

      consumer_context =
        receive do
          {^trace_ref,
           {:trace, pid, :call,
            {^consumer, :preflight, [_plan, _poll_result, _configuration, context]}}}
          when pid == self() ->
            context
        after
          1_000 -> flunk("consumer preflight was not called")
        end

      {result, consumer_context}
    after
      :erlang.trace_pattern({consumer, :preflight, 4}, false, [])
      :erlang.trace(self(), false, [:call])
      send(tracer, :stop)
    end
  end

  defp forward_traces(owner, trace_ref) do
    receive do
      :stop ->
        :ok

      message ->
        send(owner, {trace_ref, message})
        forward_traces(owner, trace_ref)
    end
  end

  defp consumer_cooldowns(%StarterConsumerContext{entries: [entry]}),
    do: entry.input.cooldowns

  defp consumer_cooldowns(%ConversationConsumerContext{entries: [entry]}),
    do: entry.input.starter.cooldowns

  defp cooldown(persona_id, spoken_at) do
    %PersonaCooldownRecord{
      persona_id: persona_id,
      last_spoken_at: spoken_at,
      cooldown_until: DateTime.add(spoken_at, 60, :second)
    }
    |> Ecto.put_meta(state: :loaded)
  end
end

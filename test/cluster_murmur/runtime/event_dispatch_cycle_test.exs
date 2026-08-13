defmodule ClusterMurmur.Runtime.EventDispatchCycleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{
    EventDispatch,
    EventDispatchCandidate,
    EventDispatchClaim,
    PersonaCooldownRecord
  }

  alias ClusterMurmur.Runtime.EventDispatchCycle
  alias ClusterMurmur.Runtime.EventDispatchCycle.{Adapters, Context, ConversationRuntime, Result}
  alias ClusterMurmur.Runtime.EventDispatchExecutor
  alias ClusterMurmur.Runtime.ResponderTurnCycle.Adapters, as: ResponderAdapters
  alias ClusterMurmur.Runtime.ResponderTurnSchedule
  alias ClusterMurmur.Runtime.ResponderTurnSchedule.Step
  alias ClusterMurmur.TestSupport.RuntimeFixture

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.Adapters,
    as: ConversationAdapters

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer,
    as: ConversationConsumer

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.Context,
    as: ConversationConsumerContext

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.SharedInput

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer,
    as: StarterConsumer

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Context,
    as: StarterConsumerContext

  alias ClusterMurmur.Triggers.EventDispatchPlanner.Plan

  @now ~U[2026-08-08 17:00:00.000000Z]

  defmodule Dispatches do
    alias ClusterMurmur.Persistence.{EventDispatch, EventDispatchClaim}
    alias ClusterMurmur.Runtime.EventDispatchCycleTest, as: Test

    def list_available(now) do
      trace({:list, now})
      Process.get({Test, :candidates}, {:ok, []})
    end

    def claim(candidate, now) do
      trace({:claim, candidate.event_id})

      case Map.get(Process.get({Test, :claim_failures}, %{}), candidate.event_id) do
        nil ->
          {:ok,
           %EventDispatchClaim{
             event_id: candidate.event_id,
             enqueued_at: candidate.enqueued_at,
             token: token(candidate.event_id),
             started_at: now,
             expires_at: DateTime.add(now, 60, :second)
           }}

        failure ->
          failure
      end
    end

    def complete(claim, now) do
      trace({:complete, claim.event_id})

      case Map.get(Process.get({Test, :completion_failures}, %{}), claim.event_id) do
        nil ->
          {:ok,
           %EventDispatch{
             event_id: claim.event_id,
             status: :completed,
             enqueued_at: claim.enqueued_at,
             claim_token: nil,
             claim_started_at: nil,
             claim_expires_at: nil,
             completed_at: normalize_precision(now)
           }}

        failure ->
          failure
      end
    end

    defp token(event_id),
      do: :sha256 |> :crypto.hash(event_id) |> Base.url_encode64(padding: false)

    defp normalize_precision(%DateTime{microsecond: {microsecond, _precision}} = datetime),
      do: %{datetime | microsecond: {microsecond, 6}}

    defp trace(call),
      do: Process.put({Test, :trace}, Process.get({Test, :trace}, []) ++ [call])
  end

  defmodule Events do
    alias ClusterMurmur.Runtime.EventDispatchCycleTest, as: Test

    def fetch(event_id) do
      trace({:fetch, event_id})

      case Map.fetch(Process.get({Test, :events}, %{}), event_id) do
        {:ok, event} -> {:ok, event}
        :error -> {:error, :event_not_found}
      end
    end

    defp trace(call),
      do: Process.put({Test, :trace}, Process.get({Test, :trace}, []) ++ [call])
  end

  defmodule Authorizer do
    alias ClusterMurmur.Runtime.EventDispatchCycleTest, as: Test

    def authorize(trigger, event, now, event_policy) do
      Process.put({Test, :event_policies}, [event_policy | policies()])
      trace({:authorize, event.id, trigger.id, now})

      Map.get(
        Process.get({Test, :authorization_results}, %{}),
        event.id,
        {:skip, :already_terminal}
      )
    end

    defp trace(call),
      do: Process.put({Test, :trace}, Process.get({Test, :trace}, []) ++ [call])

    defp policies, do: Process.get({Test, :event_policies}, [])
  end

  defmodule PipelineAdapters do
    alias ClusterMurmur.Runtime.EventDispatchCycleTest, as: Test

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
      trace({:fetch_cooldown, persona_id})
      Process.get({Test, :cooldown, persona_id}, {:ok, nil})
    end

    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def complete(_conversation_id, _completed_at), do: :unused
    def wait(_conversation), do: :unused
    def claim_generation(_conversation, _persona_id), do: :unused
    def consume_generation(_conversation, _persona_id), do: :unused
    def confirm_completed(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused

    defp trace(call),
      do: Process.put({Test, :trace}, Process.get({Test, :trace}, []) ++ [call])
  end

  setup do
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :candidates}, {:ok, []})
    Process.put({__MODULE__, :events}, %{})
    Process.put({__MODULE__, :claim_failures}, %{})
    Process.put({__MODULE__, :completion_failures}, %{})
    Process.put({__MODULE__, :authorization_results}, %{})
    Process.put({__MODULE__, :event_policies}, [])
    :ok
  end

  test "claims and completes one terminally skipped matching event" do
    configuration = RuntimeFixture.configuration()

    event = %{
      event("event-a", "observation.failed")
      | dedupe_key: "observation.failed:example-target"
    }

    put_batch([event])

    assert {:ok, %Result{} = result} =
             EventDispatchCycle.run(configuration, @now, context(configuration), adapters())

    assert result.candidate_count == 1
    assert result.claimed_count == 1
    assert result.completed_count == 1
    assert result.candidate_failure_count == 0
    assert result.planned_match_count == 1
    assert result.attempted_match_count == 1
    assert result.dispatched_count == 0
    assert result.skipped_count == 1
    assert result.dispatch_failure_count == 0

    assert Process.get({__MODULE__, :trace}) == [
             {:fetch_cooldown, "caretaker"},
             {:list, @now},
             {:fetch, "event-a"},
             {:claim, "event-a"},
             {:authorize, "event-a", "failure-conversation", @now},
             {:complete, "event-a"}
           ]

    assert Process.get({__MODULE__, :event_policies}) == [configuration.event_policy]

    refute inspect(result) =~ "event-a"
    refute inspect(context(configuration)) =~ "clearly-fake-api-key"
  end

  test "completes an unmatched event without authorizing a trigger" do
    configuration = RuntimeFixture.configuration()
    event = event("event-a", "observation.recovered")
    put_batch([event])

    assert {:ok, result} =
             EventDispatchCycle.run(configuration, @now, context(configuration), adapters())

    assert result.completed_count == 1
    assert result.planned_match_count == 0
    assert result.attempted_match_count == 0
    assert result.candidate_failure_count == 0

    assert Process.get({__MODULE__, :trace}) == [
             {:fetch_cooldown, "caretaker"},
             {:list, @now},
             {:fetch, "event-a"},
             {:claim, "event-a"},
             {:complete, "event-a"}
           ]
  end

  test "reports durable dedupe suppression without exposing its key" do
    configuration = RuntimeFixture.configuration()

    event = %{
      event("event-a", "observation.failed")
      | dedupe_key: "observation.failed:example-target"
    }

    put_batch([event])
    Process.put({__MODULE__, :authorization_results}, %{"event-a" => {:skip, :dedupe_window}})

    assert {:ok, result} =
             EventDispatchCycle.run(configuration, @now, context(configuration), adapters())

    assert result.completed_count == 1
    assert result.skipped_count == 1
    assert result.dedupe_suppressed_count == 1
    refute inspect(result) =~ event.dedupe_key
  end

  test "validates reusable runtime dependencies without reading the outbox" do
    configuration = RuntimeFixture.configuration()
    valid_context = context(configuration)
    valid_adapters = adapters()

    assert EventDispatchCycle.validate_runtime(
             configuration,
             valid_context,
             valid_adapters
           ) == :ok

    assert Process.get({__MODULE__, :trace}) == []

    for {candidate_configuration, candidate_context, candidate_adapters} <- [
          {%{configuration | version: 1.0}, valid_context, valid_adapters},
          {configuration, %{valid_context | shared_input: nil}, valid_adapters},
          {configuration, valid_context, %{valid_adapters | events: String}}
        ] do
      assert EventDispatchCycle.validate_runtime(
               candidate_configuration,
               candidate_context,
               candidate_adapters
             ) == {:error, :invalid_event_dispatch_cycle}
    end

    assert Process.get({__MODULE__, :trace}) == []
  end

  test "fails before reading the outbox when the current cooldown snapshot cannot load" do
    configuration = RuntimeFixture.configuration()
    Process.put({__MODULE__, :cooldown, "caretaker"}, {:error, :storage_unavailable})

    assert EventDispatchCycle.run(configuration, @now, context(configuration), adapters()) ==
             {:error, :event_dispatch_failed}

    assert Process.get({__MODULE__, :trace}) == [{:fetch_cooldown, "caretaker"}]
  end

  test "applies changed fetched cooldowns on every starter and conversation cycle" do
    event = event("event-a", "observation.failed")
    put_batch([event])

    for {configuration, build_context, consumer} <- [
          {RuntimeFixture.configuration(), &context/1, StarterConsumer},
          {RuntimeFixture.responder_configuration(),
           &conversation_context(&1, responder_schedule()), ConversationConsumer}
        ] do
      persona_ids = configuration.personas.personas |> Map.keys() |> Enum.sort()
      fetch_calls = Enum.map(persona_ids, &{:fetch_cooldown, &1})

      Enum.each(persona_ids, &Process.delete({__MODULE__, :cooldown, &1}))
      Process.put({__MODULE__, :trace}, [])
      cycle_context = build_context.(configuration)

      assert EventDispatchCycle.validate_runtime(configuration, cycle_context, adapters()) == :ok

      {result, consumer_context} =
        capture_consumer_context(consumer, fn ->
          EventDispatchCycle.run(configuration, @now, cycle_context, adapters())
        end)

      assert {:ok, %Result{candidate_count: 1, planned_match_count: 1}} = result
      assert consumer_cooldowns(consumer_context) == %{}
      assert Enum.take(Process.get({__MODULE__, :trace}), length(fetch_calls)) == fetch_calls

      refreshed_cooldowns =
        Map.new(persona_ids, fn persona_id ->
          record = cooldown(persona_id)
          Process.put({__MODULE__, :cooldown, persona_id}, {:ok, record})
          {persona_id, record}
        end)

      Process.put({__MODULE__, :trace}, [])

      {result, consumer_context} =
        capture_consumer_context(consumer, fn ->
          EventDispatchCycle.run(configuration, @now, build_context.(configuration), adapters())
        end)

      assert {:ok, %Result{candidate_count: 1, planned_match_count: 1}} = result
      assert consumer_cooldowns(consumer_context) == refreshed_cooldowns
      assert Enum.take(Process.get({__MODULE__, :trace}), length(fetch_calls)) == fetch_calls
    end
  end

  test "accepts storage-normalized completion precision for the same instant" do
    configuration = RuntimeFixture.configuration()
    event = event("event-a", "observation.recovered")
    put_batch([event])
    coarse_now = ~U[2026-08-08 17:00:00Z]

    assert {:ok, result} =
             EventDispatchCycle.run(configuration, coarse_now, context(configuration), adapters())

    assert result.completed_count == 1
    assert result.candidate_failure_count == 0
  end

  test "continues after a claim conflict and preserves unattempted match counts" do
    configuration = RuntimeFixture.configuration()
    events = [event("event-a", "observation.failed"), event("event-b", "observation.failed")]
    put_batch(events)
    Process.put({__MODULE__, :claim_failures}, %{"event-a" => {:error, :dispatch_conflict}})

    assert {:ok, result} =
             EventDispatchCycle.run(configuration, @now, context(configuration), adapters())

    assert result.candidate_count == 2
    assert result.claimed_count == 1
    assert result.completed_count == 1
    assert result.candidate_failure_count == 1
    assert result.planned_match_count == 2
    assert result.attempted_match_count == 1
    assert result.skipped_count == 1
    assert result.dispatch_failure_count == 0

    assert {:claim, "event-b"} in Process.get({__MODULE__, :trace})
    assert {:complete, "event-b"} in Process.get({__MODULE__, :trace})
    refute {:complete, "event-a"} in Process.get({__MODULE__, :trace})
  end

  test "leaves a claimed entry open after authorization or completion failure" do
    configuration = RuntimeFixture.configuration()
    event = event("event-a", "observation.failed")

    for {authorization_results, completion_failures, expected_dispatch_failures} <- [
          {%{"event-a" => {:error, :storage_unavailable}}, %{}, 1},
          {%{}, %{"event-a" => {:error, :storage_unavailable}}, 0}
        ] do
      Process.put({__MODULE__, :trace}, [])
      put_batch([event])
      Process.put({__MODULE__, :authorization_results}, authorization_results)
      Process.put({__MODULE__, :completion_failures}, completion_failures)

      assert {:ok, result} =
               EventDispatchCycle.run(configuration, @now, context(configuration), adapters())

      assert result.claimed_count == 1
      assert result.completed_count == 0
      assert result.candidate_failure_count == 1
      assert result.dispatch_failure_count == expected_dispatch_failures
    end
  end

  test "leaves a claimed entry open while its durable execution is still in progress" do
    configuration = RuntimeFixture.configuration()
    event = event("event-a", "observation.failed")
    put_batch([event])

    Process.put(
      {__MODULE__, :authorization_results},
      %{"event-a" => {:skip, :execution_in_progress}}
    )

    assert {:ok, result} =
             EventDispatchCycle.run(configuration, @now, context(configuration), adapters())

    assert result.claimed_count == 1
    assert result.completed_count == 0
    assert result.candidate_failure_count == 1
    assert result.attempted_match_count == 1
    assert result.skipped_count == 0
    assert result.dispatch_failure_count == 1
    refute {:complete, "event-a"} in Process.get({__MODULE__, :trace})
  end

  test "rejects malformed runtime and durable loads before the first claim" do
    configuration = RuntimeFixture.configuration()
    valid_context = context(configuration)
    invalid_context = Map.put(valid_context, :private, true)

    assert EventDispatchCycle.run(configuration, @now, invalid_context, adapters()) ==
             {:error, :invalid_event_dispatch_cycle}

    assert Process.get({__MODULE__, :trace}) == []

    event_a = event("event-a", "observation.failed")
    event_b = event("event-b", "observation.failed")
    Process.put({__MODULE__, :events}, %{"event-a" => event_a, "event-b" => event_b})

    Process.put(
      {__MODULE__, :candidates},
      {:ok, [candidate("event-b"), candidate("event-a")]}
    )

    assert EventDispatchCycle.run(configuration, @now, valid_context, adapters()) ==
             {:error, :invalid_event_dispatch_cycle}

    refute Enum.any?(Process.get({__MODULE__, :trace}), &match?({:claim, _event_id}, &1))

    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :candidates}, {:ok, [candidate("missing")]})

    assert EventDispatchCycle.run(configuration, @now, valid_context, adapters()) ==
             {:error, :event_dispatch_failed}

    refute Enum.any?(Process.get({__MODULE__, :trace}), &match?({:claim, _event_id}, &1))

    Process.put({__MODULE__, :trace}, [])

    oversized =
      Enum.map(0..100, fn index ->
        event(
          "event-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          "observation.failed"
        )
      end)

    put_batch(oversized)

    assert EventDispatchCycle.run(configuration, @now, valid_context, adapters()) ==
             {:error, :invalid_event_dispatch_cycle}

    assert Enum.count(Process.get({__MODULE__, :trace}), &match?({:fetch, _event_id}, &1)) == 100
    refute Enum.any?(Process.get({__MODULE__, :trace}), &match?({:claim, _event_id}, &1))
  end

  test "validates only exact correlated aggregate results" do
    valid = %Result{
      candidate_count: 2,
      claimed_count: 1,
      completed_count: 1,
      candidate_failure_count: 1,
      planned_match_count: 2,
      attempted_match_count: 1,
      dispatched_count: 0,
      skipped_count: 1,
      dispatch_failure_count: 0
    }

    assert EventDispatchCycle.validate_result(valid) == :ok

    assert EventDispatchCycle.validate_result(%{valid | dedupe_suppressed_count: 2}) ==
             {:error, :invalid_event_dispatch_cycle}

    for invalid <- [
          %{valid | candidate_count: 1},
          %{valid | claimed_count: 0},
          %{valid | attempted_match_count: 2},
          %{valid | skipped_count: -1},
          %{
            valid
            | candidate_count: 0,
              claimed_count: 0,
              completed_count: 0,
              candidate_failure_count: 0,
              planned_match_count: 1,
              attempted_match_count: 0,
              skipped_count: 0
          },
          %{
            valid
            | claimed_count: 0,
              completed_count: 0,
              candidate_failure_count: 2,
              attempted_match_count: 1,
              skipped_count: 1
          },
          %{
            valid
            | candidate_count: 1,
              claimed_count: 1,
              completed_count: 1,
              candidate_failure_count: 0,
              planned_match_count: 1,
              attempted_match_count: 0,
              skipped_count: 0
          },
          %{
            valid
            | planned_match_count: 1,
              attempted_match_count: 1,
              skipped_count: 0,
              dispatch_failure_count: 1
          },
          Map.put(valid, :private, true)
        ] do
      assert EventDispatchCycle.validate_result(invalid) ==
               {:error, :invalid_event_dispatch_cycle}
    end
  end

  test "rejects direct execution without an exact bounded plan or fixed consumer" do
    configuration = RuntimeFixture.configuration()

    plan = %Plan{
      executed_at: @now,
      candidate_count: 0,
      matched_event_count: 0,
      match_count: 0,
      entries: []
    }

    consumer_context = %StarterConsumerContext{entries: [], adapters: pipeline_adapters()}

    assert EventDispatchExecutor.execute(
             Map.put(plan, :private, true),
             configuration,
             @now,
             StarterConsumer,
             consumer_context,
             adapters()
           ) == {:error, :invalid_event_dispatch_cycle}

    assert EventDispatchExecutor.execute(
             plan,
             configuration,
             @now,
             __MODULE__,
             consumer_context,
             adapters()
           ) == {:error, :invalid_event_dispatch_cycle}

    assert Process.get({__MODULE__, :trace}) == []
  end

  defp put_batch(events) do
    Process.put({__MODULE__, :events}, Map.new(events, &{&1.id, &1}))
    Process.put({__MODULE__, :candidates}, {:ok, Enum.map(events, &candidate(&1.id))})
  end

  defp candidate(event_id) do
    %EventDispatchCandidate{event_id: event_id, enqueued_at: @now}
  end

  defp event(event_id, type) do
    RuntimeFixture.event(
      id: event_id,
      type: type,
      occurred_at: DateTime.add(@now, -1, :second)
    )
  end

  defp adapters do
    %Adapters{dispatches: Dispatches, events: Events, authorizer: Authorizer}
  end

  defp context(configuration) do
    %Context{
      shared_input: shared_input(configuration),
      adapters: pipeline_adapters()
    }
  end

  defp conversation_context(configuration, schedule) do
    starter_adapters = pipeline_adapters()

    %Context{
      shared_input: shared_input(configuration),
      adapters: starter_adapters,
      conversation_runtime: %ConversationRuntime{
        schedule: schedule,
        adapters: %ConversationAdapters{
          starter: starter_adapters,
          responder: %ResponderAdapters{
            random: PipelineAdapters,
            conversation_store: PipelineAdapters,
            provider: PipelineAdapters,
            message_store: PipelineAdapters,
            publication_start_store: PipelineAdapters,
            publisher: PipelineAdapters,
            publication_terminal_store: PipelineAdapters,
            cooldown_store: PipelineAdapters
          }
        }
      }
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

  defp capture_consumer_context(consumer, run_cycle) do
    owner = self()
    trace_ref = make_ref()
    tracer = spawn(fn -> forward_traces(owner, trace_ref) end)

    Code.ensure_loaded!(consumer)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern({consumer, :preflight, 3}, true, [])

    try do
      result = run_cycle.()

      consumer_context =
        receive do
          {^trace_ref,
           {:trace, pid, :call, {^consumer, :preflight, [_plan, _configuration, context]}}}
          when pid == self() ->
            context
        after
          1_000 -> flunk("consumer preflight was not called")
        end

      {result, consumer_context}
    after
      :erlang.trace_pattern({consumer, :preflight, 3}, false, [])
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

  defp cooldown(persona_id) do
    %PersonaCooldownRecord{
      persona_id: persona_id,
      last_spoken_at: @now,
      cooldown_until: DateTime.add(@now, 60, :second)
    }
    |> Ecto.put_meta(state: :loaded)
  end

  defp pipeline_adapters do
    %AuthorizedStarterPipeline.Adapters{
      conversation_action_store: PipelineAdapters,
      provider: PipelineAdapters,
      message_store: PipelineAdapters,
      publication_start_store: PipelineAdapters,
      publisher: PipelineAdapters,
      publication_terminal_store: PipelineAdapters,
      cooldown_store: PipelineAdapters,
      conversation_store: PipelineAdapters,
      starter_random: PipelineAdapters,
      reply_random: PipelineAdapters
    }
  end
end

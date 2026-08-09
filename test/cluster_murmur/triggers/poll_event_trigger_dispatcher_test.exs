defmodule ClusterMurmur.Triggers.PollEventTriggerDispatcherTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Triggers
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult

  alias ClusterMurmur.Triggers.{
    EventTrigger,
    PollEventTriggerDispatcher,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.PollEventTriggerDispatcher.Result
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  defmodule FakeAuthorizer do
    def authorize(trigger, event, executed_at, event_policy) do
      Process.put({__MODULE__, :calls}, calls() ++ [{event.id, trigger.id}])
      record({:authorize, {event.id, trigger.id}})

      case Map.get(Process.get({__MODULE__, :responses}, %{}), {event.id, trigger.id}, :build) do
        :build ->
          ClusterMurmur.Triggers.EventTriggerAuthorizer.authorize(
            trigger,
            event,
            executed_at,
            event_policy,
            ClusterMurmur.Triggers.PollEventTriggerDispatcherTest.FakeStore
          )

        :raise ->
          raise "private authorizer diagnostic"

        response ->
          response
      end
    end

    defp calls, do: Process.get({__MODULE__, :calls}, [])

    defp record(entry) do
      trace = Process.get({ClusterMurmur.Triggers.PollEventTriggerDispatcherTest, :trace}, [])

      Process.put(
        {ClusterMurmur.Triggers.PollEventTriggerDispatcherTest, :trace},
        trace ++ [entry]
      )
    end
  end

  defmodule FakeStore do
    def start(plan) do
      Process.put({__MODULE__, :policies}, [plan.event_policy | policies()])

      {:ok,
       %ClusterMurmur.Persistence.TriggerExecution{
         trigger_id: plan.trigger.id,
         event_id: plan.event.id,
         status: :started,
         executed_at: plan.executed_at,
         cooldown_until: plan.cooldown_until,
         error_class: nil
       }
       |> Ecto.put_meta(state: :loaded)}
    end

    defp policies, do: Process.get({__MODULE__, :policies}, [])
  end

  defmodule FakeConsumer do
    @behaviour ClusterMurmur.Triggers.AuthorizedStarterConsumer

    @impl true
    def preflight(_plan, _poll_result, _configuration, :process_dictionary) do
      record(:preflight)
      :ok
    end

    def preflight(_plan, _poll_result, _configuration, _context) do
      record({:preflight, :invalid})
      {:error, :invalid_context}
    end

    @impl true
    def consume(authorization, index, :process_dictionary) do
      key = {authorization.plan.event.id, authorization.plan.trigger.id}
      Process.put({__MODULE__, :calls}, calls() ++ [{index, key}])
      record({:consume, index, key})

      case Map.get(Process.get({__MODULE__, :responses}, %{}), index, :ok) do
        :raise -> raise "private consumer diagnostic"
        response -> response
      end
    end

    defp calls, do: Process.get({__MODULE__, :calls}, [])

    defp record(entry) do
      trace = Process.get({ClusterMurmur.Triggers.PollEventTriggerDispatcherTest, :trace}, [])

      Process.put(
        {ClusterMurmur.Triggers.PollEventTriggerDispatcherTest, :trace},
        trace ++ [entry]
      )
    end
  end

  setup do
    Process.put({FakeAuthorizer, :calls}, [])
    Process.put({FakeAuthorizer, :responses}, %{})
    Process.put({FakeConsumer, :calls}, [])
    Process.put({FakeConsumer, :responses}, %{})
    Process.put({FakeStore, :policies}, [])
    Process.put({__MODULE__, :trace}, [])
    :ok
  end

  test "authorizes and immediately dispatches every match in stable order" do
    events = [event("event-b", "observation.failed"), event("event-a", "observation.recovered")]

    configuration =
      configuration([
        trigger("z-failure", "observation.failed"),
        trigger("b-recovery", "observation.recovered"),
        trigger("a-failure", "observation.failed")
      ])

    poll_result = poll_result(events)
    plan = plan(poll_result, configuration)

    assert {:ok, %Result{} = result} =
             PollEventTriggerDispatcher.dispatch(
               plan,
               poll_result,
               configuration,
               FakeConsumer,
               :process_dictionary,
               FakeAuthorizer
             )

    assert result.match_count == 3
    assert result.dispatched_count == 3
    assert result.skipped_count == 0
    assert result.failure_count == 0

    assert Enum.map(result.outcomes, &{&1.status, &1.reason}) ==
             List.duplicate({:dispatched, nil}, 3)

    expected = [
      {"event-b", "a-failure"},
      {"event-b", "z-failure"},
      {"event-a", "b-recovery"}
    ]

    assert Process.get({FakeAuthorizer, :calls}) == expected
    assert Process.get({FakeConsumer, :calls}) == Enum.with_index(expected, &{&2, &1})

    assert Process.get({FakeStore, :policies}) ==
             List.duplicate(configuration.event_policy, 3)

    assert Process.get({__MODULE__, :trace}) == [
             :preflight,
             {:authorize, {"event-b", "a-failure"}},
             {:consume, 0, {"event-b", "a-failure"}},
             {:authorize, {"event-b", "z-failure"}},
             {:consume, 1, {"event-b", "z-failure"}},
             {:authorize, {"event-a", "b-recovery"}},
             {:consume, 2, {"event-a", "b-recovery"}}
           ]

    refute inspect(result) =~ "event-b"
    refute inspect(result) =~ "Authorization"
  end

  test "continues after correlated skips, authorization failures, and consumer failures" do
    configuration =
      configuration([
        trigger("first", "observation.failed"),
        trigger("second", "observation.failed"),
        trigger("third", "observation.failed"),
        trigger("fourth", "observation.failed")
      ])

    Process.put(
      {FakeAuthorizer, :responses},
      %{
        {"event-a", "first"} => {:skip, :cooldown},
        {"event-a", "fourth"} => {:error, :storage_unavailable},
        {"event-a", "second"} => :raise
      }
    )

    Process.put({FakeConsumer, :responses}, %{3 => :raise})

    poll_result = poll_result([event("event-a", "observation.failed")])
    plan = plan(poll_result, configuration)

    assert {:ok, result} =
             PollEventTriggerDispatcher.dispatch(
               plan,
               poll_result,
               configuration,
               FakeConsumer,
               :process_dictionary,
               FakeAuthorizer
             )

    assert result.match_count == 4
    assert result.dispatched_count == 0
    assert result.skipped_count == 1
    assert result.failure_count == 3

    assert Enum.map(result.outcomes, &{&1.status, &1.reason}) == [
             {:skipped, :cooldown},
             {:failed, :storage_unavailable},
             {:failed, :authorization_failed},
             {:failed, :dispatch_failed}
           ]

    assert Process.get({FakeConsumer, :calls}) == [{3, {"event-a", "third"}}]
  end

  test "preflights all fixed module contracts before authorization" do
    configuration = configuration([trigger("failure", "observation.failed")])
    poll_result = poll_result([event("event-a", "observation.failed")])
    plan = plan(poll_result, configuration)

    invalid = [
      {%{plan | match_count: 0}, poll_result, configuration, FakeConsumer, FakeAuthorizer},
      {plan, %{poll_result | event_count: 0}, configuration, FakeConsumer, FakeAuthorizer},
      {plan, poll_result, %{configuration | version: 1.0}, FakeConsumer, FakeAuthorizer},
      {plan, poll_result, configuration, String, FakeAuthorizer},
      {plan, poll_result, configuration, FakeConsumer, String},
      {plan, poll_result, configuration, FakeConsumer, FakeAuthorizer, :invalid_context}
    ]

    for candidate <- invalid do
      {candidate_plan, candidate_poll, candidate_configuration, consumer, authorizer, context} =
        case candidate do
          {candidate_plan, candidate_poll, candidate_configuration, consumer, authorizer} ->
            {candidate_plan, candidate_poll, candidate_configuration, consumer, authorizer,
             :process_dictionary}

          values ->
            values
        end

      assert PollEventTriggerDispatcher.dispatch(
               candidate_plan,
               candidate_poll,
               candidate_configuration,
               consumer,
               context,
               authorizer
             ) == {:error, :invalid_poll_event_dispatch}
    end

    assert Process.get({FakeAuthorizer, :calls}) == []
    assert Process.get({FakeConsumer, :calls}) == []
    assert Process.get({__MODULE__, :trace}) == [{:preflight, :invalid}]
  end

  defp plan(poll_result, configuration) do
    {:ok, plan} = PollEventTriggerPlanner.plan(poll_result, configuration, @executed_at)
    plan
  end

  defp configuration(event_triggers) do
    base = RuntimeFixture.configuration()
    trigger_map = Map.new(event_triggers, &{&1.id, &1})
    %{base | triggers: %Triggers{triggers: trigger_map}}
  end

  defp poll_result(events) do
    %PollResult{
      target_count: length(events),
      ingested_count: length(events),
      event_count: length(events),
      failure_count: 0,
      events: events,
      failures: []
    }
  end

  defp trigger(id, type) do
    %EventTrigger{
      id: id,
      matcher: %Matcher{
        predicates: [%Predicate{field: "type", operator: :equals, value: type}]
      },
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: 60_000
    }
  end

  defp event(id, type), do: RuntimeFixture.event(id: id, type: type)
end

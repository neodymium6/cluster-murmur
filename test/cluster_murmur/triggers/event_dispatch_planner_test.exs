defmodule ClusterMurmur.Triggers.EventDispatchPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Triggers
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Persistence.EventDispatchCandidate
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.{EventDispatchPlanner, EventTrigger}
  alias ClusterMurmur.Triggers.EventDispatchPlanner.Plan

  @enqueued_at ~U[2026-08-08 16:00:00.000000Z]
  @executed_at ~U[2026-08-08 16:00:01.000000Z]

  test "plans every durable candidate and matching triggers in stable order" do
    candidates = [candidate("event-a"), candidate("event-b"), candidate("event-c", 1)]

    events = [
      event("event-a", "observation.failed"),
      event("event-b", "observation.recovered"),
      event("event-c", "observation.unchanged", 1)
    ]

    configuration =
      configuration([
        trigger("z-failure", "observation.failed"),
        trigger("b-recovery", "observation.recovered"),
        trigger("a-failure", "observation.failed")
      ])

    assert {:ok, %Plan{} = plan} =
             EventDispatchPlanner.plan(candidates, events, configuration, @executed_at)

    assert plan.candidate_count == 3
    assert plan.matched_event_count == 2
    assert plan.match_count == 3
    assert Enum.map(plan.entries, & &1.candidate.event_id) == ~w(event-a event-b event-c)

    assert Enum.map(plan.entries, fn entry -> Enum.map(entry.triggers, & &1.id) end) == [
             ["a-failure", "z-failure"],
             ["b-recovery"],
             []
           ]

    assert EventDispatchPlanner.validate(plan, candidates, events, configuration) == :ok
    assert EventDispatchPlanner.validate(plan, configuration) == :ok
    refute inspect(plan) =~ "event-a"
    refute inspect(plan) =~ "private"
  end

  test "accepts an empty available batch" do
    assert {:ok, plan} =
             EventDispatchPlanner.plan([], [], configuration([]), @executed_at)

    assert plan.candidate_count == 0
    assert plan.matched_event_count == 0
    assert plan.match_count == 0
    assert plan.entries == []
  end

  test "rejects uncorrelated, unsorted, future, and forged candidates" do
    event_a = event("event-a", "observation.failed")
    event_b = event("event-b", "observation.failed")
    configuration = configuration([trigger("failure", "observation.failed")])

    invalid_batches = [
      {[candidate("event-b"), candidate("event-a")], [event_b, event_a]},
      {[candidate("event-a")], [event_b]},
      {[%{candidate("event-a") | enqueued_at: DateTime.add(@executed_at, 1, :second)}],
       [event_a]},
      {[candidate("event-a")], [%{event_a | occurred_at: DateTime.add(@enqueued_at, 1)}]},
      {[Map.put(candidate("event-a"), :private, true)], [event_a]},
      {[candidate("event-a")], []}
    ]

    for {candidates, events} <- invalid_batches do
      assert EventDispatchPlanner.plan(candidates, events, configuration, @executed_at) ==
               {:error, :invalid_event_dispatch_plan}
    end
  end

  test "rejects candidate and aggregate match overflow before later mutation" do
    candidates =
      Enum.map(0..100, fn index ->
        candidate("event-#{String.pad_leading(Integer.to_string(index), 3, "0")}")
      end)

    events = Enum.map(candidates, &event(&1.event_id, "observation.failed"))

    assert EventDispatchPlanner.plan(candidates, events, configuration([]), @executed_at) ==
             {:error, :too_many_dispatch_candidates}

    triggers = Enum.map(1..129, &trigger("trigger-#{&1}", "observation.failed"))
    two_candidates = [candidate("event-a"), candidate("event-b")]
    two_events = Enum.map(two_candidates, &event(&1.event_id, "observation.failed"))

    assert EventDispatchPlanner.plan(
             two_candidates,
             two_events,
             configuration(triggers),
             @executed_at
           ) == {:error, :too_many_trigger_matches}
  end

  test "rejects forged plans and revalidates the current configuration" do
    candidates = [candidate("event-a")]
    events = [event("event-a", "observation.failed")]
    configuration = configuration([trigger("failure", "observation.failed")])

    assert {:ok, plan} =
             EventDispatchPlanner.plan(candidates, events, configuration, @executed_at)

    for forged <- [
          nil,
          %{plan | candidate_count: 0},
          %{plan | entries: []},
          %{plan | entries: List.duplicate(hd(plan.entries), 101)},
          Map.put(plan, :private, true)
        ] do
      assert EventDispatchPlanner.validate(forged, candidates, events, configuration) ==
               {:error, :invalid_event_dispatch_plan}

      assert EventDispatchPlanner.validate(forged, configuration) ==
               {:error, :invalid_event_dispatch_plan}
    end

    changed = configuration([trigger("recovery", "observation.recovered")])

    assert EventDispatchPlanner.validate(plan, candidates, events, changed) ==
             {:error, :invalid_event_dispatch_plan}
  end

  defp configuration(event_triggers) do
    base = RuntimeFixture.configuration()
    trigger_map = Map.new(event_triggers, &{&1.id, &1})
    %{base | triggers: %Triggers{triggers: trigger_map}}
  end

  defp candidate(event_id, offset_seconds \\ 0) do
    %EventDispatchCandidate{
      event_id: event_id,
      enqueued_at: DateTime.add(@enqueued_at, offset_seconds, :second)
    }
  end

  defp event(event_id, type, offset_seconds \\ 0) do
    RuntimeFixture.event(
      id: event_id,
      type: type,
      occurred_at: DateTime.add(@enqueued_at, offset_seconds - 1, :second)
    )
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
end

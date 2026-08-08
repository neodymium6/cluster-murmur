defmodule ClusterMurmur.Triggers.PollEventTriggerPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Triggers
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult
  alias ClusterMurmur.Triggers.{EventTrigger, PollEventTriggerPlanner}
  alias ClusterMurmur.Triggers.PollEventTriggerPlanner.Plan
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  test "plans matching poll events and triggers in deterministic order" do
    events = [event("event-b", "observation.failed"), event("event-a", "observation.recovered")]

    configuration =
      configuration([
        trigger("z-failure", "observation.failed"),
        trigger("b-recovery", "observation.recovered"),
        trigger("a-failure", "observation.failed")
      ])

    poll_result = poll_result(events)

    assert {:ok, %Plan{} = plan} =
             PollEventTriggerPlanner.plan(poll_result, configuration, @executed_at)

    assert plan.event_count == 2
    assert plan.matched_event_count == 2
    assert plan.match_count == 3
    assert Enum.map(plan.entries, & &1.event.id) == ["event-b", "event-a"]

    assert Enum.map(plan.entries, fn entry -> Enum.map(entry.triggers, & &1.id) end) == [
             ["a-failure", "z-failure"],
             ["b-recovery"]
           ]

    assert PollEventTriggerPlanner.validate(plan, poll_result, configuration) == :ok
    refute inspect(plan) =~ "event-b"
    refute inspect(plan) =~ "private"
  end

  test "keeps unmatched events in the poll count without creating work entries" do
    poll_result = poll_result([event("event-a", "observation.recovered")])
    configuration = configuration([trigger("failure", "observation.failed")])

    assert {:ok, plan} =
             PollEventTriggerPlanner.plan(poll_result, configuration, @executed_at)

    assert plan.event_count == 1
    assert plan.matched_event_count == 0
    assert plan.match_count == 0
    assert plan.entries == []
  end

  test "rejects duplicate events, time reversal, and aggregate match overflow" do
    duplicate = event("duplicate", "observation.failed")
    configuration = configuration([trigger("failure", "observation.failed")])

    assert PollEventTriggerPlanner.plan(
             poll_result([duplicate, duplicate]),
             configuration,
             @executed_at
           ) == {:error, :duplicate_poll_event}

    assert PollEventTriggerPlanner.plan(
             poll_result([event("future", "observation.failed", @executed_at)]),
             configuration,
             DateTime.add(@executed_at, -1, :microsecond)
           ) == {:error, :invalid_datetime}

    triggers = Enum.map(1..256, &trigger("trigger-#{&1}", "observation.failed"))

    assert PollEventTriggerPlanner.plan(
             poll_result([
               event("event-1", "observation.failed"),
               event("event-2", "observation.failed")
             ]),
             configuration(triggers),
             @executed_at
           ) == {:error, :too_many_trigger_matches}
  end

  test "rejects forged inputs and revalidates against current configuration" do
    poll_result = poll_result([event("event-a", "observation.failed")])
    configuration = configuration([trigger("failure", "observation.failed")])

    assert {:ok, plan} =
             PollEventTriggerPlanner.plan(poll_result, configuration, @executed_at)

    invalid_poll = %{poll_result | event_count: 0}
    invalid_configuration = %{configuration | version: 1.0}

    assert PollEventTriggerPlanner.plan(invalid_poll, configuration, @executed_at) ==
             {:error, :invalid_poll}

    assert PollEventTriggerPlanner.plan(poll_result, invalid_configuration, @executed_at) ==
             {:error, :invalid_configuration}

    for forged <- [
          nil,
          %{plan | match_count: 0},
          %{plan | entries: []},
          Map.put(plan, :private, true)
        ] do
      assert PollEventTriggerPlanner.validate(forged, poll_result, configuration) ==
               {:error, :invalid_poll_trigger_plan}
    end

    changed_configuration =
      configuration([trigger("recovery", "observation.recovered")])

    assert PollEventTriggerPlanner.validate(plan, poll_result, changed_configuration) ==
             {:error, :invalid_poll_trigger_plan}
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

  defp event(id, type, occurred_at \\ ~U[2026-08-07 01:59:59.000000Z]) do
    RuntimeFixture.event(id: id, type: type, occurred_at: occurred_at)
  end
end

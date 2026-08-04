defmodule ClusterMurmur.Triggers.EventTriggerExecutionPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerExecutionPlanner}
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan

  test "builds a redacted plan for one matching eligible trigger" do
    trigger = trigger()
    event = event()
    executed_at = ~U[2026-08-04 12:00:00.000000Z]

    assert {:ok, %Plan{} = plan} =
             EventTriggerExecutionPlanner.plan(trigger, event, nil, executed_at)

    assert plan.trigger == trigger
    assert plan.event == event
    assert plan.executed_at == executed_at
    assert plan.cooldown_until == ~U[2026-08-04 12:01:00.000000Z]

    inspected = inspect(plan)
    refute inspected =~ trigger.id
    refute inspected =~ event.id
    refute inspected =~ "private"
    refute inspected =~ "2026"
  end

  test "skips an active cooldown at the supplied execution instant" do
    assert EventTriggerExecutionPlanner.plan(
             trigger(),
             event(),
             ~U[2026-08-04 12:00:00.000001Z],
             ~U[2026-08-04 12:00:00.000000Z]
           ) == {:skip, :cooldown}
  end

  test "skips a nonmatching trigger without evaluating cooldown state" do
    event = %{event() | type: "observation.recovered"}
    forged_cooldown = %{~U[2026-08-04 12:00:00Z] | hour: 24}

    assert EventTriggerExecutionPlanner.plan(trigger(), event, forged_cooldown, nil) ==
             {:skip, :not_matched}
  end

  test "preserves stable validation errors without exposing supplied values" do
    valid_trigger = trigger()
    valid_event = event()

    invalid_matcher = %{valid_trigger.matcher | predicates: []}
    forged_datetime = %{~U[2026-08-04 12:00:00Z] | hour: 24}

    results = [
      EventTriggerExecutionPlanner.plan(nil, valid_event, nil, forged_datetime),
      EventTriggerExecutionPlanner.plan(
        %{valid_trigger | matcher: invalid_matcher},
        valid_event,
        nil,
        forged_datetime
      ),
      EventTriggerExecutionPlanner.plan(
        valid_trigger,
        %{valid_event | id: ""},
        nil,
        forged_datetime
      ),
      EventTriggerExecutionPlanner.plan(valid_trigger, valid_event, nil, forged_datetime),
      EventTriggerExecutionPlanner.plan(
        valid_trigger,
        valid_event,
        forged_datetime,
        forged_datetime
      )
    ]

    assert results == [
             {:error, :invalid_trigger},
             {:error, :invalid_trigger_matcher},
             {:error, :invalid_event},
             {:error, :invalid_datetime},
             {:error, :invalid_datetime}
           ]

    refute inspect(results) =~ "private"
  end

  test "rejects forged trigger and event structures" do
    valid_trigger = trigger()
    valid_event = event()

    assert EventTriggerExecutionPlanner.plan(
             Map.put(valid_trigger, :unexpected_private_value, "private"),
             valid_event,
             nil,
             ~U[2026-08-04 12:00:00Z]
           ) == {:error, :invalid_trigger}

    assert EventTriggerExecutionPlanner.plan(
             valid_trigger,
             Map.put(valid_event, :unexpected_private_value, "private"),
             nil,
             ~U[2026-08-04 12:00:00Z]
           ) == {:error, :invalid_event}
  end

  defp trigger do
    %EventTrigger{
      id: "failure-conversation",
      matcher: %Matcher{
        predicates: [%Predicate{field: "type", operator: :equals, value: "observation.failed"}]
      },
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: 60_000
    }
  end

  defp event do
    %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      severity: "warning",
      occurred_at: ~U[2026-08-04 11:59:59.000000Z],
      facts: %{"detail" => "private"}
    }
  end
end

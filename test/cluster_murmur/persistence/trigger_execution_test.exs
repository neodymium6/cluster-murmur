defmodule ClusterMurmur.Persistence.TriggerExecutionTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Persistence.TriggerExecution
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerExecutionPlanner}

  test "builds a redacted started record from a complete eligible plan" do
    plan = plan!()

    assert %{valid?: true} =
             changeset = TriggerExecution.start_changeset(%TriggerExecution{}, plan)

    execution = Ecto.Changeset.apply_changes(changeset)

    assert execution.trigger_id == plan.trigger.id
    assert execution.event_id == plan.event.id
    assert execution.status == :started
    assert execution.executed_at == plan.executed_at
    assert execution.cooldown_until == plan.cooldown_until
    assert execution.error_class == nil
  end

  test "rejects malformed or forged plans without retaining their values" do
    valid = plan!()

    invalid = [
      nil,
      Map.put(valid, :unexpected_private_value, "private"),
      %{valid | trigger: %{valid.trigger | id: "invalid id"}},
      %{valid | event: %{valid.event | id: ""}},
      %{valid | event: %{valid.event | type: "observation.recovered"}},
      %{valid | executed_at: %{valid.executed_at | hour: 24}},
      %{valid | cooldown_until: valid.executed_at}
    ]

    for rejected <- invalid do
      changeset = TriggerExecution.start_changeset(%TriggerExecution{}, rejected)
      refute changeset.valid?
      refute inspect(changeset) =~ "private"
    end
  end

  test "redacts records and valid changesets" do
    plan = plan!()
    changeset = TriggerExecution.start_changeset(%TriggerExecution{}, plan)
    execution = Ecto.Changeset.apply_changes(changeset)

    for inspected <- [inspect(execution), inspect(changeset)] do
      refute inspected =~ plan.trigger.id
      refute inspected =~ plan.event.id
      refute inspected =~ "2026"
      refute inspected =~ "private"
    end
  end

  defp plan! do
    assert {:ok, plan} =
             EventTriggerExecutionPlanner.plan(
               trigger(),
               event(),
               nil,
               ~U[2026-08-04 12:00:00.000000Z]
             )

    plan
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
      occurred_at: ~U[2026-08-04 11:59:59.000000Z],
      facts: %{"detail" => "private"}
    }
  end
end

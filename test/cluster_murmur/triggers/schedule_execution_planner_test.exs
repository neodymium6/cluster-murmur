defmodule ClusterMurmur.Triggers.ScheduleExecutionPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{ScheduleState, ScheduleStateClaim}
  alias ClusterMurmur.Triggers.{EmittedEvent, ScheduleExecutionPlanner, ScheduleTrigger}
  alias ClusterMurmur.Triggers.ScheduleExecutionPlanner.Plan

  @due ~U[2026-08-10 12:00:00.000000Z]
  @executed_at ~U[2026-08-10 12:00:01.000000Z]

  test "builds one redacted factual plan and advances after the execution instant" do
    trigger = trigger("0 * * * *")
    state = state()
    claim = claim()

    assert {:ok, plan} = ScheduleExecutionPlanner.plan(trigger, state, claim, @executed_at)

    assert %Plan{
             claim: ^claim,
             event: event,
             executed_at: @executed_at,
             next_run_at: ~U[2026-08-10 13:00:00Z]
           } = plan

    assert event == trigger.event
    refute inspect(plan) =~ "daily-summary"
    refute inspect(plan) =~ claim.token
    refute inspect(plan) =~ "2026"

    delayed = ~U[2026-08-10 14:10:00.000000Z]
    delayed_claim = claim(started_at: delayed, expires_at: DateTime.add(delayed, 60, :second))

    assert {:ok, %Plan{next_run_at: ~U[2026-08-10 15:00:00Z]}} =
             ScheduleExecutionPlanner.plan(trigger, state, delayed_claim, delayed)
  end

  test "requires an exact fully validated trigger before using its facts" do
    valid = trigger("0 * * * *")

    invalid = [
      nil,
      %{valid | id: "bad id"},
      %{valid | timezone: String.duplicate("a", 129)},
      %{valid | cron: %{valid.cron | minute: [99]}},
      %{valid | cron: %{valid.cron | minute: [1 | 2]}},
      %{valid | cron: %{valid.cron | minute: List.duplicate(1, 10_000)}},
      %{valid | event: %{valid.event | subject: "bad subject"}},
      %{valid | event: Map.put(valid.event, :private, "private")},
      Map.put(valid, :private, "private")
    ]

    for rejected <- invalid do
      assert ScheduleExecutionPlanner.plan(rejected, state(), claim(), @executed_at) ==
               {:error, :invalid_trigger}
    end
  end

  test "requires an exact claim-free correlated due projection" do
    token = claim().token

    claimed_state =
      state(
        claim_token: token,
        claim_started_at: @due,
        claim_expires_at: DateTime.add(@due, 60, :second)
      )

    invalid = [
      nil,
      state(trigger_id: "other"),
      state(next_run_at: %{@due | month: 13}),
      claimed_state,
      %{state() | __meta__: nil},
      Map.put(state(), :private, "private")
    ]

    for rejected <- invalid do
      assert ScheduleExecutionPlanner.plan(
               trigger("0 * * * *"),
               rejected,
               claim(),
               @executed_at
             ) == {:error, :invalid_schedule}
    end
  end

  test "distinguishes a valid future projection from malformed state" do
    future = state(next_run_at: DateTime.add(@executed_at, 1, :second))
    future_claim = claim(expected_next_run_at: future.next_run_at)

    assert ScheduleExecutionPlanner.plan(
             trigger("0 * * * *"),
             future,
             future_claim,
             @executed_at
           ) == {:error, :schedule_not_due}
  end

  test "requires an exact correlated live fixed-duration claim" do
    valid = claim()

    invalid = [
      nil,
      %{valid | trigger_id: "other"},
      %{valid | expected_next_run_at: DateTime.add(@due, -1, :second)},
      %{valid | token: "invalid"},
      %{valid | token: String.duplicate("A", 1_000_000)},
      %{valid | started_at: DateTime.add(@due, -1, :second)},
      %{valid | expires_at: DateTime.add(@due, 59, :second)},
      %{valid | started_at: %{@due | hour: 24}},
      Map.put(valid, :private, "private")
    ]

    for rejected <- invalid do
      assert ScheduleExecutionPlanner.plan(
               trigger("0 * * * *"),
               state(),
               rejected,
               @executed_at
             ) == {:error, :invalid_claim}
    end

    assert ScheduleExecutionPlanner.plan(
             trigger("0 * * * *"),
             state(),
             valid,
             valid.expires_at
           ) == {:error, :invalid_claim}
  end

  test "rejects malformed or non-UTC execution instants" do
    invalid = [
      nil,
      %{@executed_at | hour: 24},
      %{@executed_at | time_zone: "Asia/Tokyo"}
    ]

    for executed_at <- invalid do
      assert ScheduleExecutionPlanner.plan(
               trigger("0 * * * *"),
               state(),
               claim(),
               executed_at
             ) == {:error, :invalid_datetime}
    end
  end

  test "preserves a bounded no-next-run failure" do
    due = ~U[9999-12-31 23:58:00.000000Z]
    executed_at = DateTime.add(due, 1, :second)

    assert ScheduleExecutionPlanner.plan(
             trigger("0 0 1 1 *"),
             state(next_run_at: due),
             claim(
               expected_next_run_at: due,
               started_at: due,
               expires_at: DateTime.add(due, 60, :second)
             ),
             executed_at
           ) == {:error, :no_next_run}
  end

  defp trigger(cron) do
    {:ok, expression} = Crontab.CronExpression.Parser.parse(cron, false)

    %ScheduleTrigger{
      id: "daily-summary",
      cron: expression,
      timezone: "Etc/UTC",
      action: :emit_event,
      event: %EmittedEvent{
        type: "schedule.fired",
        group: "social",
        subject: "daily-summary"
      }
    }
  end

  defp state(overrides \\ []) do
    ScheduleState
    |> struct!(
      Keyword.merge(
        [
          trigger_id: "daily-summary",
          next_run_at: @due,
          last_run_at: nil,
          claim_token: nil,
          claim_started_at: nil,
          claim_expires_at: nil
        ],
        overrides
      )
    )
    |> Ecto.put_meta(state: :loaded)
  end

  defp claim(overrides \\ []) do
    struct!(
      ScheduleStateClaim,
      Keyword.merge(
        [
          trigger_id: "daily-summary",
          expected_next_run_at: @due,
          token: Base.url_encode64(<<1::256>>, padding: false),
          started_at: @due,
          expires_at: DateTime.add(@due, 60, :second)
        ],
        overrides
      )
    )
  end
end

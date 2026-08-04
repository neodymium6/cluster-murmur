defmodule ClusterMurmur.Triggers.StochasticDueEvaluatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.StochasticSchedule
  alias ClusterMurmur.Triggers.{ActiveHours, EmittedEvent, StochasticDueEvaluator}
  alias ClusterMurmur.Triggers.{StochasticEligibility, StochasticTrigger}
  alias ClusterMurmur.Triggers.StochasticEligibility.Decision

  test "uses a matching persisted local-date count" do
    trigger = trigger(window(8 * 60, 23 * 60, "Etc/UTC"), 3)
    schedule = schedule(daily_count: 3, daily_count_date: ~D[2026-08-04])

    assert StochasticDueEvaluator.evaluate(trigger, schedule, ~U[2026-08-04 12:00:00Z]) ==
             {:ok,
              %Decision{
                eligible: false,
                reason: :daily_limit_reached,
                local_date: ~D[2026-08-04]
              }}
  end

  test "resets an absent or previous local-date count before policy evaluation" do
    trigger = trigger(window(8 * 60, 23 * 60, "Etc/UTC"), 3)

    for stale <- [
          schedule(daily_count: 0, daily_count_date: nil),
          schedule(daily_count: 10_000, daily_count_date: ~D[2026-08-03])
        ] do
      assert StochasticDueEvaluator.evaluate(trigger, stale, ~U[2026-08-04 12:00:00Z]) ==
               {:ok,
                %Decision{
                  eligible: true,
                  reason: :eligible,
                  local_date: ~D[2026-08-04]
                }}
    end
  end

  test "preserves active-hours precedence and unconstrained policy" do
    constrained = trigger(window(8 * 60, 23 * 60, "Etc/UTC"), 3)

    assert StochasticDueEvaluator.evaluate(
             constrained,
             schedule(daily_count: 3, daily_count_date: ~D[2026-08-04]),
             ~U[2026-08-04 23:00:00Z]
           ) ==
             {:ok,
              %Decision{
                eligible: false,
                reason: :outside_active_hours,
                local_date: ~D[2026-08-04]
              }}

    assert StochasticDueEvaluator.evaluate(
             trigger(nil, nil),
             schedule(daily_count: 9, daily_count_date: ~D[2026-08-03]),
             ~U[2026-08-04 12:00:00Z]
           ) == {:ok, %Decision{eligible: true, reason: :eligible, local_date: nil}}
  end

  test "requires an exact unclaimed due schedule projection" do
    trigger = trigger(nil, nil)
    token = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)

    invalid = [
      schedule(trigger_id: "other"),
      schedule(daily_count: -1),
      schedule(daily_count: 3, daily_count_date: "2026-08-04"),
      schedule(daily_count: "3", daily_count_date: ~D[2026-08-04]),
      schedule(next_run_at: DateTime.new!(~D[2026-08-04], ~T[12:00:00], "Asia/Tokyo")),
      schedule(
        claim_token: token,
        claim_started_at: ~U[2026-08-04 11:59:00Z],
        claim_expires_at: ~U[2026-08-04 12:00:00Z]
      )
    ]

    for rejected <- invalid do
      assert StochasticDueEvaluator.evaluate(trigger, rejected, ~U[2026-08-04 12:00:00Z]) ==
               {:error, :invalid_schedule}
    end

    assert StochasticDueEvaluator.evaluate(
             trigger,
             schedule(next_run_at: ~U[2026-08-04 12:00:00.000001Z]),
             ~U[2026-08-04 12:00:00Z]
           ) == {:error, :schedule_not_due}
  end

  test "rejects invalid instants and forged triggers without retaining values" do
    trigger = trigger(nil, nil)
    forged_now = %{~U[2026-08-04 12:00:00Z] | hour: 24}

    assert StochasticDueEvaluator.evaluate(trigger, schedule(), forged_now) ==
             {:error, :invalid_datetime}

    assert StochasticDueEvaluator.evaluate(
             %{trigger | distribution: :uniform},
             schedule(),
             ~U[2026-08-04 12:00:00Z]
           ) == {:error, :invalid_trigger}

    assert StochasticDueEvaluator.evaluate(
             %{trigger | distribution: :uniform},
             schedule(next_run_at: ~U[2026-08-04 13:00:00Z]),
             ~U[2026-08-04 12:00:00Z]
           ) == {:error, :invalid_trigger}

    result =
      StochasticDueEvaluator.evaluate(
        trigger,
        schedule(trigger_id: "private-trigger"),
        ~U[2026-08-04 12:00:00Z]
      )

    assert result == {:error, :invalid_schedule}
    refute inspect(result) =~ "private"
  end

  test "exposes the validated local bucket without weakening direct count checks" do
    trigger = trigger(window(23 * 60, 8 * 60, "Asia/Tokyo"), 3)

    assert StochasticEligibility.local_bucket(trigger, ~U[2026-08-04 16:00:00Z]) ==
             {:ok, ~D[2026-08-05]}

    assert StochasticEligibility.evaluate(
             trigger,
             ~U[2026-08-04 16:00:00Z],
             {~D[2026-08-04], 0}
           ) == {:error, :invalid_execution_count}
  end

  defp trigger(active_hours, daily_limit) do
    %StochasticTrigger{
      id: "ambient",
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: active_hours,
      daily_limit: daily_limit,
      action: :emit_event,
      event: %EmittedEvent{type: "stochastic.fired", group: "social", subject: "ambient"}
    }
  end

  defp schedule(overrides \\ []) do
    struct!(
      StochasticSchedule,
      Keyword.merge(
        [
          trigger_id: "ambient",
          next_run_at: ~U[2026-08-04 12:00:00Z],
          last_run_at: nil,
          daily_count: 0,
          daily_count_date: nil,
          claim_token: nil,
          claim_started_at: nil,
          claim_expires_at: nil
        ],
        overrides
      )
    )
  end

  defp window(start_minute, end_minute, timezone) do
    %ActiveHours{start_minute: start_minute, end_minute: end_minute, timezone: timezone}
  end
end

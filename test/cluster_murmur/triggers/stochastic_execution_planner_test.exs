defmodule ClusterMurmur.Triggers.StochasticExecutionPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{StochasticSchedule, StochasticScheduleClaim}
  alias ClusterMurmur.Triggers.{ActiveHours, EmittedEvent, StochasticExecutionPlanner}
  alias ClusterMurmur.Triggers.StochasticTrigger
  alias ClusterMurmur.Triggers.StochasticExecutionPlanner.Plan
  alias ClusterMurmur.Triggers.StochasticEligibility.Decision

  defmodule ZeroRandom do
    def uniform, do: 0.0
  end

  defmodule RaisingRandom do
    def uniform, do: raise("private random failure")
  end

  test "builds a redacted plan for one eligible claimed execution" do
    trigger = trigger(nil, nil)
    schedule = schedule()
    claim = claim()
    executed_at = ~U[2026-08-04 12:00:01Z]

    assert {:ok, plan} =
             StochasticExecutionPlanner.plan(
               trigger,
               schedule,
               claim,
               executed_at,
               ZeroRandom
             )

    assert %Plan{} = plan
    assert plan.claim == claim
    assert plan.event == trigger.event
    assert plan.executed_at == executed_at
    assert plan.next_run_at == ~U[2026-08-04 12:00:03.000Z]
    assert plan.local_date == nil

    inspected = inspect(plan)
    refute inspected =~ "ambient"
    refute inspected =~ claim.token
    refute inspected =~ "2026"
  end

  test "uses the execution instant's validated local daily bucket" do
    trigger = trigger(window(8 * 60, 23 * 60, "Etc/UTC"), 3)
    schedule = schedule(daily_count: 2, daily_count_date: ~D[2026-08-04])

    assert {:ok, %Plan{local_date: ~D[2026-08-04]}} =
             StochasticExecutionPlanner.plan(
               trigger,
               schedule,
               claim(),
               ~U[2026-08-04 12:00:01Z],
               ZeroRandom
             )
  end

  test "skips an ineligible execution without sampling" do
    trigger = trigger(window(8 * 60, 23 * 60, "Etc/UTC"), 3)
    schedule = schedule(daily_count: 3, daily_count_date: ~D[2026-08-04])

    assert StochasticExecutionPlanner.plan(
             trigger,
             schedule,
             claim(),
             ~U[2026-08-04 12:00:01Z],
             RaisingRandom
           ) ==
             {:skip,
              %Decision{
                eligible: false,
                reason: :daily_limit_reached,
                local_date: ~D[2026-08-04]
              }}
  end

  test "requires an exact live fixed-duration claim before sampling" do
    valid = claim()

    invalid = [
      nil,
      %{valid | trigger_id: "other"},
      %{valid | expected_next_run_at: ~U[2026-08-04 11:59:00Z]},
      %{valid | token: "invalid"},
      %{valid | started_at: ~U[2026-08-04 11:59:59Z]},
      %{valid | expires_at: ~U[2026-08-04 12:00:59Z]}
    ]

    for rejected <- invalid do
      assert StochasticExecutionPlanner.plan(
               trigger(nil, nil),
               schedule(),
               rejected,
               ~U[2026-08-04 12:00:01Z],
               RaisingRandom
             ) == {:error, :invalid_claim}
    end

    assert StochasticExecutionPlanner.plan(
             trigger(nil, nil),
             schedule(),
             valid,
             valid.expires_at,
             RaisingRandom
           ) == {:error, :invalid_claim}
  end

  test "preserves due-state and trigger validation errors" do
    valid_trigger = trigger(nil, nil)

    assert StochasticExecutionPlanner.plan(
             valid_trigger,
             schedule(next_run_at: ~U[2026-08-04 12:00:02Z]),
             %{claim() | expected_next_run_at: ~U[2026-08-04 12:00:02Z]},
             ~U[2026-08-04 12:00:01Z],
             RaisingRandom
           ) == {:error, :schedule_not_due}

    for subject <- ["invalid subject", String.duplicate("a", 16 * 1_024 + 1)] do
      invalid_event = %{valid_trigger.event | subject: subject}

      assert StochasticExecutionPlanner.plan(
               %{valid_trigger | event: invalid_event},
               schedule(),
               claim(),
               ~U[2026-08-04 12:00:01Z],
               RaisingRandom
             ) == {:error, :invalid_trigger}
    end

    forged_datetime = %{~U[2026-08-04 12:00:01Z] | hour: 24}

    assert StochasticExecutionPlanner.plan(
             valid_trigger,
             schedule(),
             claim(),
             forged_datetime,
             RaisingRandom
           ) == {:error, :invalid_datetime}
  end

  test "preserves scheduling failures without producing a plan" do
    result =
      StochasticExecutionPlanner.plan(
        trigger(nil, nil),
        schedule(),
        claim(),
        ~U[2026-08-04 12:00:01Z],
        RaisingRandom
      )

    assert result == {:error, :invalid_random_source}
    refute inspect(result) =~ "private"

    near_limit =
      trigger(nil, nil)
      |> Map.merge(%{mean_interval_ms: 121_000, minimum_interval_ms: 120_000})

    assert StochasticExecutionPlanner.plan(
             near_limit,
             schedule(next_run_at: ~U[9999-12-31 23:58:00Z]),
             claim(
               expected_next_run_at: ~U[9999-12-31 23:58:00Z],
               started_at: ~U[9999-12-31 23:58:00Z],
               expires_at: ~U[9999-12-31 23:59:00Z]
             ),
             ~U[9999-12-31 23:58:01Z],
             ZeroRandom
           ) == {:error, :no_next_run}
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

  defp claim(overrides \\ []) do
    struct!(
      StochasticScheduleClaim,
      Keyword.merge(
        [
          trigger_id: "ambient",
          expected_next_run_at: ~U[2026-08-04 12:00:00Z],
          token: Base.url_encode64(:binary.copy(<<1>>, 32), padding: false),
          started_at: ~U[2026-08-04 12:00:00Z],
          expires_at: ~U[2026-08-04 12:01:00Z]
        ],
        overrides
      )
    )
  end

  defp window(start_minute, end_minute, timezone) do
    %ActiveHours{start_minute: start_minute, end_minute: end_minute, timezone: timezone}
  end
end

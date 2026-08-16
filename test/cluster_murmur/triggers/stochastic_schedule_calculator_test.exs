defmodule ClusterMurmur.Triggers.StochasticScheduleCalculatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Triggers.{
    ActiveHours,
    ActiveHoursEvaluator,
    EmittedEvent,
    StochasticScheduleCalculator,
    StochasticTrigger
  }

  defmodule ZeroRandom do
    def uniform, do: 0.0
  end

  defmodule HalfRandom do
    def uniform, do: 0.5
  end

  defmodule InvalidRandom do
    def uniform, do: 1.0
  end

  defmodule RaisingRandom do
    def uniform, do: raise("private random failure")
  end

  defmodule CountingRandom do
    def uniform do
      Process.put(
        :stochastic_schedule_sample_count,
        Process.get(:stochastic_schedule_sample_count, 0) + 1
      )

      0.0
    end
  end

  test "adds one sampled wait to the supplied UTC instant" do
    base = ~U[2026-08-04 12:00:00.123456Z]

    assert StochasticScheduleCalculator.next_run(trigger(), base, ZeroRandom) ==
             {:ok, ~U[2026-08-04 12:00:02.123456Z]}

    assert StochasticScheduleCalculator.next_run(trigger(), base, HalfRandom) ==
             {:ok, ~U[2026-08-04 12:00:06.281456Z]}
  end

  test "is deterministic for the same base instant and random source" do
    base = ~U[2026-08-04 12:00:00Z]

    assert StochasticScheduleCalculator.next_run(trigger(), base, HalfRandom) ==
             StochasticScheduleCalculator.next_run(trigger(), base, HalfRandom)
  end

  test "samples exactly once for one next-run calculation" do
    Process.put(:stochastic_schedule_sample_count, 0)

    assert {:ok, _next_run} =
             StochasticScheduleCalculator.next_run(
               trigger(),
               ~U[2026-08-04 12:00:00Z],
               CountingRandom
             )

    assert Process.get(:stochastic_schedule_sample_count) == 1
  end

  test "resamples a due schedule strictly inside the next active window" do
    trigger = trigger(active_hours(13 * 60, 14 * 60, "Etc/UTC"))

    assert StochasticScheduleCalculator.next_active_run(
             trigger,
             ~U[2026-08-04 12:00:00Z],
             ZeroRandom
           ) == {:ok, ~U[2026-08-04 13:00:02.000000Z]}

    assert StochasticScheduleCalculator.next_active_run(
             trigger,
             ~U[2026-08-04 15:00:00Z],
             HalfRandom
           ) == {:ok, ~U[2026-08-05 13:00:06.158000Z]}
  end

  test "resamples across midnight in the configured timezone" do
    trigger = trigger(active_hours(23 * 60, 8 * 60, "Asia/Tokyo"))

    assert {:ok, next_run} =
             StochasticScheduleCalculator.next_active_run(
               trigger,
               ~U[2026-08-04 12:00:00Z],
               ZeroRandom
             )

    assert next_run == ~U[2026-08-04 14:00:02.000000Z]
  end

  test "keeps replacements inside one eligible segment across a DST fold" do
    Process.put(:stochastic_schedule_sample_count, 0)

    trigger =
      trigger(active_hours(90, 23 * 60, "America/New_York"))
      |> Map.merge(%{minimum_interval_ms: 30 * 60_000, mean_interval_ms: 60 * 60_000})

    assert {:ok, from_before_fold} =
             StochasticScheduleCalculator.next_active_run(
               trigger,
               ~U[2026-11-01 04:00:00Z],
               CountingRandom
             )

    assert from_before_fold == ~U[2026-11-01 07:00:00.000000Z]
    assert {:ok, true} = ActiveHoursEvaluator.active?(trigger.active_hours, from_before_fold)
    assert Process.get(:stochastic_schedule_sample_count) == 1

    assert {:ok, second_occurrence} =
             StochasticScheduleCalculator.next_active_run(
               trigger,
               ~U[2026-11-01 06:00:00Z],
               ZeroRandom
             )

    assert second_occurrence == ~U[2026-11-01 07:00:00.000000Z]
    assert {:ok, true} = ActiveHoursEvaluator.active?(trigger.active_hours, second_occurrence)
  end

  test "uses a same-day segment reopened by an ambiguous DST closing" do
    trigger = trigger(active_hours(30, 90, "America/New_York"))
    now = ~U[2026-11-01 05:45:00Z]

    assert {:ok, false} = ActiveHoursEvaluator.active?(trigger.active_hours, now)

    assert StochasticScheduleCalculator.next_active_run(trigger, now, ZeroRandom) ==
             {:ok, ~U[2026-11-01 06:00:02.000000Z]}

    assert {:ok, true} =
             ActiveHoursEvaluator.active?(
               trigger.active_hours,
               ~U[2026-11-01 06:00:02.000000Z]
             )
  end

  test "finds the first eligible instant after a DST gap" do
    trigger = trigger(active_hours(150, 4 * 60, "America/New_York"))

    assert {:ok, next_run} =
             StochasticScheduleCalculator.next_active_run(
               trigger,
               ~U[2026-03-08 06:00:00Z],
               ZeroRandom
             )

    assert next_run == ~U[2026-03-08 07:00:02.000000Z]
    assert {:ok, true} = ActiveHoursEvaluator.active?(trigger.active_hours, next_run)
  end

  test "skips a local active window completely swallowed by a DST gap" do
    Process.put(:stochastic_schedule_sample_count, 0)
    trigger = trigger(active_hours(2 * 60 + 15, 2 * 60 + 45, "America/New_York"))

    assert StochasticScheduleCalculator.next_active_run(
             trigger,
             ~U[2026-03-07 12:00:00Z],
             CountingRandom
           ) == {:ok, ~U[2026-03-09 06:15:02.000000Z]}

    assert Process.get(:stochastic_schedule_sample_count) == 1
  end

  test "does not consume randomness for an already active window" do
    trigger = trigger(active_hours(12 * 60, 13 * 60, "Etc/UTC"))

    assert StochasticScheduleCalculator.next_active_run(
             trigger,
             ~U[2026-08-04 12:30:00Z],
             RaisingRandom
           ) == {:error, :already_active}
  end

  test "requires a canonical UTC base before sampling" do
    {:ok, local} =
      DateTime.shift_zone(
        ~U[2026-08-04 12:00:00Z],
        "Europe/Berlin",
        TimeZoneInfo.TimeZoneDatabase
      )

    forged = %{~U[2026-08-04 12:00:00Z] | utc_offset: 3_600, zone_abbr: "PRIVATE"}

    unsupported_year =
      10_000
      |> NaiveDateTime.new!(1, 1, 0, 0, 0)
      |> DateTime.from_naive!("Etc/UTC")

    for invalid <- [nil, local, forged, unsupported_year] do
      assert StochasticScheduleCalculator.next_run(trigger(), invalid, RaisingRandom) ==
               {:error, :invalid_datetime}

      assert StochasticScheduleCalculator.next_active_run(
               trigger(active_hours(13 * 60, 14 * 60, "Etc/UTC")),
               invalid,
               RaisingRandom
             ) == {:error, :invalid_datetime}
    end
  end

  test "rejects a sampled run beyond the durable datetime range" do
    assert StochasticScheduleCalculator.next_run(
             trigger(),
             ~U[9999-12-31 23:59:57.999000Z],
             ZeroRandom
           ) == {:ok, ~U[9999-12-31 23:59:59.999000Z]}

    assert StochasticScheduleCalculator.next_run(
             trigger(),
             ~U[9999-12-31 23:59:58Z],
             ZeroRandom
           ) == {:error, :no_next_run}
  end

  test "preserves stable sampler errors" do
    assert StochasticScheduleCalculator.next_run(nil, ~U[2026-08-04 12:00:00Z], ZeroRandom) ==
             {:error, :invalid_trigger}

    invalid_trigger = %{trigger() | minimum_interval_ms: 0}

    assert StochasticScheduleCalculator.next_run(
             invalid_trigger,
             ~U[2026-08-04 12:00:00Z],
             RaisingRandom
           ) == {:error, :invalid_trigger}

    assert StochasticScheduleCalculator.next_run(
             trigger(),
             ~U[2026-08-04 12:00:00Z],
             InvalidRandom
           ) == {:error, :invalid_random_value}

    result =
      StochasticScheduleCalculator.next_run(
        trigger(),
        ~U[2026-08-04 12:00:00Z],
        RaisingRandom
      )

    assert result == {:error, :invalid_random_source}
    refute inspect(result) =~ "private"
  end

  defp trigger(active_hours \\ nil) do
    %StochasticTrigger{
      id: "ambient",
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: active_hours,
      daily_limit: nil,
      action: :emit_event,
      event: %EmittedEvent{type: "stochastic.fired", group: "social", subject: "ambient"}
    }
  end

  defp active_hours(start_minute, end_minute, timezone) do
    %ActiveHours{
      start_minute: start_minute,
      end_minute: end_minute,
      timezone: timezone
    }
  end
end

defmodule ClusterMurmur.Triggers.StochasticScheduleCalculatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Triggers.{
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

  defp trigger do
    %StochasticTrigger{
      id: "ambient",
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: nil,
      daily_limit: nil,
      action: :emit_event,
      event: %EmittedEvent{type: "stochastic.fired", group: "social", subject: "ambient"}
    }
  end
end

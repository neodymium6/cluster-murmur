defmodule ClusterMurmur.Triggers.ActiveHoursEvaluatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Triggers.{ActiveHours, ActiveHoursEvaluator}

  test "treats an omitted window as unrestricted" do
    assert ActiveHoursEvaluator.active?(nil, ~U[2026-08-04 00:00:00Z]) == {:ok, true}
  end

  test "uses inclusive start and exclusive end in the configured timezone" do
    active_hours = window(8 * 60, 23 * 60, "Asia/Tokyo")

    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-03 23:00:00Z]) == {:ok, true}
    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-04 13:59:59Z]) == {:ok, true}
    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-04 14:00:00Z]) == {:ok, false}
    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-04 22:59:59Z]) == {:ok, false}
  end

  test "supports a window that crosses local midnight" do
    active_hours = window(23 * 60, 8 * 60, "Etc/UTC")

    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-04 23:00:00Z]) == {:ok, true}
    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-05 07:59:59Z]) == {:ok, true}
    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-05 08:00:00Z]) == {:ok, false}
    assert ActiveHoursEvaluator.active?(active_hours, ~U[2026-08-04 12:00:00Z]) == {:ok, false}
  end

  test "evaluates both instants of a DST fold by their shared wall time" do
    active_hours = window(60, 120, "America/New_York")

    assert ActiveHoursEvaluator.active?(active_hours, ~U[2025-11-02 05:30:00Z]) == {:ok, true}
    assert ActiveHoursEvaluator.active?(active_hours, ~U[2025-11-02 06:30:00Z]) == {:ok, true}
  end

  test "rejects forged windows and datetime metadata with stable errors" do
    valid = window(60, 120, "Etc/UTC")

    for forged <- [
          %{valid | start_minute: -1},
          %{valid | end_minute: 1_440},
          %{valid | end_minute: 60},
          %{valid | timezone: "private.invalid"}
        ] do
      assert ActiveHoursEvaluator.active?(forged, ~U[2026-08-04 00:00:00Z]) ==
               {:error, :invalid_active_hours}
    end

    forged_datetime = %{~U[2026-08-04 00:00:00Z] | utc_offset: 3_600, zone_abbr: "PRIVATE"}
    assert ActiveHoursEvaluator.active?(valid, forged_datetime) == {:error, :invalid_datetime}

    for forged <- [
          %{~U[2026-08-04 01:30:00Z] | hour: 24},
          %{~U[2026-08-04 01:30:00Z] | minute: 60},
          %{~U[2026-08-04 01:30:00Z] | second: 60},
          %{~U[2026-08-04 01:30:00Z] | microsecond: {1_000_000, 6}},
          %{~U[2026-08-04 01:30:00Z] | microsecond: {0, 7}}
        ] do
      assert ActiveHoursEvaluator.active?(valid, forged) == {:error, :invalid_datetime}
    end

    assert ActiveHoursEvaluator.active?(valid, nil) == {:error, :invalid_datetime}
    assert ActiveHoursEvaluator.active?(nil, nil) == {:error, :invalid_datetime}

    assert ActiveHoursEvaluator.active?(%{}, ~U[2026-08-04 00:00:00Z]) ==
             {:error, :invalid_active_hours}
  end

  defp window(start_minute, end_minute, timezone) do
    %ActiveHours{
      start_minute: start_minute,
      end_minute: end_minute,
      timezone: timezone
    }
  end
end

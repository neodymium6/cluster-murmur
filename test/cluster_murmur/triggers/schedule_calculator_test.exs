defmodule ClusterMurmur.Triggers.ScheduleCalculatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Triggers.{EmittedEvent, ScheduleCalculator, ScheduleTrigger}

  test "returns the first matching instant strictly after the input in UTC" do
    trigger = trigger("0 21 * * *", "Asia/Tokyo")

    assert ScheduleCalculator.next_run(trigger, ~U[2026-08-04 11:59:59Z]) ==
             {:ok, ~U[2026-08-04 12:00:00Z]}

    assert ScheduleCalculator.next_run(trigger, ~U[2026-08-04 12:00:00Z]) ==
             {:ok, ~U[2026-08-05 12:00:00Z]}
  end

  test "skips a nonexistent local time during a DST gap" do
    trigger = trigger("30 2 * * *", "America/New_York")

    assert ScheduleCalculator.next_run(trigger, ~U[2025-03-08 08:00:00Z]) ==
             {:ok, ~U[2025-03-10 06:30:00Z]}
  end

  test "runs once at the earlier occurrence during a DST fold" do
    trigger = trigger("30 1 * * *", "America/New_York")

    assert ScheduleCalculator.next_run(trigger, ~U[2025-11-01 08:00:00Z]) ==
             {:ok, ~U[2025-11-02 05:30:00Z]}

    assert ScheduleCalculator.next_run(trigger, ~U[2025-11-02 05:45:00Z]) ==
             {:ok, ~U[2025-11-03 06:30:00Z]}
  end

  test "jumps across a whole-day political timezone gap" do
    trigger = trigger("* * * * *", "Pacific/Apia")

    assert ScheduleCalculator.next_run(trigger, ~U[2011-12-30 09:59:00Z]) ==
             {:ok, ~U[2011-12-30 10:00:00Z]}
  end

  test "accepts a valid non-UTC input and still returns UTC" do
    {:ok, local} =
      DateTime.shift_zone(
        ~U[2026-08-04 11:00:00Z],
        "Europe/Berlin",
        TimeZoneInfo.TimeZoneDatabase
      )

    assert {:ok, %DateTime{time_zone: "Etc/UTC"} = next_run} =
             ScheduleCalculator.next_run(trigger("0 21 * * *", "Asia/Tokyo"), local)

    assert next_run == ~U[2026-08-04 12:00:00Z]
  end

  test "collapses forged values and dependency failures into stable errors" do
    valid = trigger("0 21 * * *", "Asia/Tokyo")

    assert ScheduleCalculator.next_run(nil, ~U[2026-08-04 00:00:00Z]) ==
             {:error, :invalid_trigger}

    assert ScheduleCalculator.next_run(valid, nil) == {:error, :invalid_datetime}

    assert ScheduleCalculator.next_run(
             %{valid | timezone: "private.invalid"},
             ~U[2026-08-04 00:00:00Z]
           ) ==
             {:error, :invalid_trigger}

    forged_cron = %{valid.cron | reboot: true}

    assert ScheduleCalculator.next_run(%{valid | cron: forged_cron}, ~U[2026-08-04 00:00:00Z]) ==
             {:error, :invalid_trigger}

    cron_with_extra_key = Map.put(valid.cron, :private, :payload)

    assert ScheduleCalculator.next_run(
             %{valid | cron: cron_with_extra_key},
             ~U[2026-08-04 00:00:00Z]
           ) == {:error, :invalid_trigger}

    forged_conditions = %{valid.cron | minute: [99]}

    assert ScheduleCalculator.next_run(
             %{valid | cron: forged_conditions},
             ~U[2026-08-04 00:00:00Z]
           ) == {:error, :invalid_trigger}

    nested_range = %{valid.cron | minute: [{:-, :*, 5}]}

    assert ScheduleCalculator.next_run(
             %{valid | cron: nested_range},
             ~U[2026-08-04 00:00:00Z]
           ) == {:error, :invalid_trigger}

    forged_datetime = %{~U[2026-08-04 00:00:00Z] | utc_offset: 3_600, zone_abbr: "PRIVATE"}

    assert ScheduleCalculator.next_run(valid, forged_datetime) == {:error, :invalid_datetime}
  end

  defp trigger(cron, timezone) do
    {:ok, expression} = Crontab.CronExpression.Parser.parse(cron, false)

    %ScheduleTrigger{
      id: "schedule",
      cron: expression,
      timezone: timezone,
      action: :emit_event,
      event: %EmittedEvent{type: "schedule.fired", group: "social", subject: "schedule"}
    }
  end
end

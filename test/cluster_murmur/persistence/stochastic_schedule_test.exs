defmodule ClusterMurmur.Persistence.StochasticScheduleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.StochasticSchedule

  test "builds bounded valid schedule changesets" do
    attributes = %{
      trigger_id: "ambient.v1",
      last_run_at: ~U[2026-08-04 12:00:00.000000Z],
      next_run_at: ~U[2026-08-04 14:00:00.000000Z],
      daily_count: 2,
      daily_count_date: ~D[2026-08-04]
    }

    assert %{valid?: true} =
             changeset = StochasticSchedule.changeset(%StochasticSchedule{}, attributes)

    assert Ecto.Changeset.apply_changes(changeset) == struct!(StochasticSchedule, attributes)
  end

  test "requires portable bounded IDs and a next run" do
    for attributes <- [
          %{},
          valid(trigger_id: "invalid id"),
          valid(trigger_id: String.duplicate("a", 16 * 1_024 + 1)),
          valid(next_run_at: nil)
        ] do
      refute StochasticSchedule.changeset(%StochasticSchedule{}, attributes).valid?
    end
  end

  test "rejects oversized IDs before portable ID validation" do
    oversized = String.duplicate("a", 1024 * 1024)

    refute StochasticSchedule.changeset(
             %StochasticSchedule{},
             valid(trigger_id: oversized)
           ).valid?
  end

  test "limits temporal years to the canonical SQLite storage range" do
    for attributes <- [
          valid(next_run_at: DateTime.new!(Date.new!(-1, 8, 4), ~T[14:00:00.000000], "Etc/UTC")),
          valid(
            last_run_at: DateTime.new!(Date.new!(10_000, 8, 4), ~T[12:00:00.000000], "Etc/UTC")
          ),
          valid(daily_count_date: Date.new!(10_000, 8, 4)),
          valid(
            claim_token: claim_token(),
            claim_started_at: ~U[2026-08-04 14:00:00.000000Z],
            claim_expires_at:
              DateTime.new!(Date.new!(10_000, 8, 4), ~T[12:00:00.000000], "Etc/UTC")
          )
        ] do
      refute StochasticSchedule.changeset(%StochasticSchedule{}, attributes).valid?
    end
  end

  test "requires a bounded opaque token and expiry as one claim pair" do
    assert StochasticSchedule.changeset(
             %StochasticSchedule{},
             valid(
               claim_token: claim_token(),
               claim_started_at: ~U[2026-08-04 14:00:00.000000Z],
               claim_expires_at: ~U[2026-08-04 14:01:00.000000Z]
             )
           ).valid?

    for attributes <- [
          valid(
            claim_token: "short",
            claim_started_at: ~U[2026-08-04 14:00:00.000000Z],
            claim_expires_at: ~U[2026-08-04 14:01:00.000000Z]
          ),
          valid(
            claim_token: claim_token(),
            claim_started_at: nil,
            claim_expires_at: ~U[2026-08-04 14:01:00.000000Z]
          ),
          valid(
            claim_token: claim_token(),
            claim_started_at: ~U[2026-08-04 14:00:00.000000Z],
            claim_expires_at: nil
          ),
          valid(
            claim_token: nil,
            claim_started_at: ~U[2026-08-04 14:00:00.000000Z],
            claim_expires_at: ~U[2026-08-04 14:01:00.000000Z]
          ),
          valid(
            claim_token: claim_token(),
            claim_started_at: ~U[2026-08-04 14:00:00.000000Z],
            claim_expires_at: ~U[2026-08-04 14:00:00.000000Z]
          )
        ] do
      refute StochasticSchedule.changeset(%StochasticSchedule{}, attributes).valid?
    end
  end

  test "bounds counters and requires a date for positive counts" do
    for attributes <- [
          valid(daily_count: -1),
          valid(daily_count: 10_001),
          valid(daily_count: 1, daily_count_date: nil)
        ] do
      refute StochasticSchedule.changeset(%StochasticSchedule{}, attributes).valid?
    end

    assert StochasticSchedule.changeset(
             %StochasticSchedule{},
             valid(daily_count: 0, daily_count_date: nil)
           ).valid?
  end

  test "requires the next run to be strictly after the last run" do
    for next_run_at <- [
          ~U[2026-08-04 12:00:00.000000Z],
          ~U[2026-08-04 11:59:59.999999Z]
        ] do
      refute StochasticSchedule.changeset(
               %StochasticSchedule{},
               valid(
                 last_run_at: ~U[2026-08-04 12:00:00.000000Z],
                 next_run_at: next_run_at
               )
             ).valid?
    end
  end

  test "rejects malformed attribute containers without raising or retaining values" do
    malformed = [
      nil,
      URI.parse("https://example.invalid/private"),
      %{"next_run_at" => "private-time", trigger_id: "private-trigger"},
      %{private: "private-value"},
      %{1 => "private-value"}
    ]

    for attributes <- malformed do
      changeset = StochasticSchedule.changeset(%StochasticSchedule{}, attributes)
      refute changeset.valid?
      refute inspect(changeset) =~ "private"
    end
  end

  test "redacts records and changesets" do
    attributes = %{
      trigger_id: "private-trigger",
      next_run_at: ~U[2026-08-04 14:00:00.000000Z],
      daily_count: 3,
      daily_count_date: ~D[2026-08-04],
      claim_token: claim_token(),
      claim_started_at: ~U[2026-08-04 14:00:00.000000Z],
      claim_expires_at: ~U[2026-08-04 14:01:00.000000Z]
    }

    schedule =
      struct!(StochasticSchedule, attributes)

    changeset = StochasticSchedule.changeset(%StochasticSchedule{}, attributes)

    for inspected <- [inspect(schedule), inspect(changeset)] do
      refute inspected =~ "private-trigger"
      refute inspected =~ "2026-08-04"
      refute inspected =~ "14:00"
      refute inspected =~ claim_token()
    end
  end

  defp valid(overrides) do
    Keyword.merge(
      [
        trigger_id: "ambient",
        next_run_at: ~U[2026-08-04 14:00:00.000000Z],
        last_run_at: nil,
        daily_count: 0,
        daily_count_date: nil
      ],
      overrides
    )
    |> Map.new()
  end

  defp claim_token, do: Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)
end

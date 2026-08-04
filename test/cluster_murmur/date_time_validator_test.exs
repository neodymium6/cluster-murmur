defmodule ClusterMurmur.DateTimeValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.DateTimeValidator

  test "accepts exact canonical UTC instants in the storage year range" do
    for datetime <- [
          ~U[0000-01-01 00:00:00.000000Z],
          ~U[2026-08-04 12:00:00Z],
          ~U[9999-12-31 23:59:59.999999Z]
        ] do
      assert DateTimeValidator.validate_storage_utc(datetime) == :ok
    end
  end

  test "rejects local, unsupported, malformed, and forged instants" do
    {:ok, local} =
      DateTime.shift_zone(
        ~U[2026-08-04 12:00:00Z],
        "Asia/Tokyo",
        TimeZoneInfo.TimeZoneDatabase
      )

    unsupported = DateTime.new!(Date.new!(10_000, 1, 1), ~T[00:00:00], "Etc/UTC")
    forged = Map.put(~U[2026-08-04 12:00:00Z], :unexpected_private_value, "private")

    for datetime <- [nil, local, unsupported, %{~U[2026-08-04 12:00:00Z] | hour: 24}, forged] do
      result = DateTimeValidator.validate_storage_utc(datetime)
      assert result == {:error, :invalid_datetime}
      refute inspect(result) =~ "private"
    end
  end
end

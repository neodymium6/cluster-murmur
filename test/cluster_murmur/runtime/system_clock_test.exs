defmodule ClusterMurmur.Runtime.SystemClockTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Runtime.SystemClock

  test "returns canonical UTC wall time" do
    assert %DateTime{} = utc_now = SystemClock.utc_now()
    assert DateTimeValidator.validate_storage_utc(utc_now) == :ok

    assert %DateTime{} = now = SystemClock.now()
    assert DateTimeValidator.validate_storage_utc(now) == :ok
  end

  test "returns monotonic time in whole milliseconds" do
    first = SystemClock.monotonic_time_ms()
    second = SystemClock.monotonic_time_ms()

    assert is_integer(first)
    assert second >= first
  end
end

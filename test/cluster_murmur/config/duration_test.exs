defmodule ClusterMurmur.Config.DurationTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Duration

  test "parses every version 1 duration unit as milliseconds" do
    assert Duration.parse("25ms") == {:ok, 25}
    assert Duration.parse("2s") == {:ok, 2_000}
    assert Duration.parse("3m") == {:ok, 180_000}
    assert Duration.parse("4h") == {:ok, 14_400_000}
    assert Duration.parse("5d") == {:ok, 432_000_000}
  end

  test "accepts zero and leading zeroes as syntactically valid durations" do
    assert Duration.parse("0ms") == {:ok, 0}
    assert Duration.parse("007s") == {:ok, 7_000}
  end

  test "rejects malformed durations without returning the input" do
    invalid_values = ["", "1", "1.5h", "-1s", "+1s", "1 s", " 1s", "1w", 1, nil]

    assert Enum.all?(invalid_values, fn value ->
             Duration.parse(value) == {:error, :invalid_duration}
           end)
  end
end

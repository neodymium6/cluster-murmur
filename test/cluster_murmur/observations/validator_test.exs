defmodule ClusterMurmur.Observations.ValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observations.{Observation, Validator}

  test "accepts exact healthy and unhealthy normalized observations" do
    for state <- [:healthy, :unhealthy] do
      assert Validator.validate(observation(state: state)) == :ok
    end
  end

  test "rejects invalid identity, state, time, payload, and shape" do
    valid = observation()

    invalid = [
      nil,
      %{valid | source: ""},
      %{valid | subject: <<255>>},
      %{valid | state: :unknown},
      %{valid | observed_at: nil},
      %{valid | facts: []},
      %{valid | labels: %{self() => "invalid"}},
      %{valid | facts: %{"value" => self()}},
      Map.put(valid, :private, true)
    ]

    for value <- invalid do
      assert Validator.validate(value) == {:error, :invalid_observation}
    end
  end

  test "shares recursive and encoded payload bounds with durable state" do
    escaped = String.duplicate(<<1>>, 16 * 1_024)

    too_deep =
      Enum.reduce(1..9, %{}, fn level, nested -> %{Integer.to_string(level) => nested} end)

    assert Validator.validate(
             observation(facts: %{"first" => escaped}, labels: %{"second" => escaped})
           ) ==
             {:error, :invalid_observation}

    assert Validator.validate(observation(facts: too_deep)) == {:error, :invalid_observation}
  end

  test "keeps inspection redacted" do
    value = observation(source: "private-source", subject: "private-subject")

    refute inspect(value) =~ "private-source"
    refute inspect(value) =~ "private-subject"
    assert inspect(value) =~ "healthy"
  end

  defp observation(overrides \\ []) do
    struct!(
      Observation,
      Keyword.merge(
        [
          source: "example-observer",
          subject: "example-target",
          state: :healthy,
          observed_at: ~U[2026-08-05 12:00:00.000000Z],
          facts: %{"attempts" => 2},
          labels: %{"category" => "monitoring"}
        ],
        overrides
      )
    )
  end
end

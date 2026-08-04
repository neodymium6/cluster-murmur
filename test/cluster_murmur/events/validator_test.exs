defmodule ClusterMurmur.Events.ValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.{Event, Validator}

  test "accepts a bounded canonical event with nested JSON-compatible facts" do
    assert Validator.validate(
             event(
               previous: %{"state" => "healthy"},
               current: %{"state" => "unhealthy"},
               facts: %{
                 "attempts" => 3,
                 "checks" => [true, nil, %{"latency" => 1.5}]
               },
               labels: %{"category" => "monitoring"},
               observed_at: ~U[2026-08-04 12:00:01Z],
               dedupe_key: "observation.failed:example-target"
             )
           ) == :ok
  end

  test "requires non-empty bounded UTF-8 strings without NUL bytes" do
    invalid = [
      event(id: ""),
      event(type: nil),
      event(source: <<255>>),
      event(subject: "example\0private"),
      event(correlation_key: String.duplicate("a", 16 * 1_024 + 1))
    ]

    for rejected <- invalid do
      assert Validator.validate(rejected) == {:error, :invalid_event}
    end
  end

  test "requires canonical storage-range UTC instants" do
    {:ok, local} =
      DateTime.shift_zone(
        ~U[2026-08-04 12:00:00Z],
        "Europe/Berlin",
        TimeZoneInfo.TimeZoneDatabase
      )

    unsupported_year =
      10_000
      |> NaiveDateTime.new!(1, 1, 0, 0, 0)
      |> DateTime.from_naive!("Etc/UTC")

    for rejected <- [
          event(occurred_at: local),
          event(occurred_at: %{~U[2026-08-04 12:00:00Z] | hour: 24}),
          event(observed_at: unsupported_year),
          event(
            occurred_at:
              Map.put(
                ~U[2026-08-04 12:00:00Z],
                :unexpected_private_payload,
                String.duplicate("x", 1024 * 1024)
              )
          )
        ] do
      assert Validator.validate(rejected) == {:error, :invalid_event}
    end
  end

  test "rejects forged event maps with fields outside the exact struct" do
    forged =
      event([])
      |> Map.put(:unexpected_private_payload, String.duplicate("x", 1024 * 1024))

    assert Validator.validate(forged) == {:error, :invalid_event}
  end

  test "rejects non-JSON and malformed payload shapes" do
    invalid = [
      event(previous: :healthy),
      event(current: URI.parse("https://example.invalid/private")),
      event(facts: []),
      event(labels: %{private: "value"}),
      event(facts: %{"values" => [1 | :improper]}),
      event(facts: %{"too-large" => 9_007_199_254_740_992})
    ]

    for rejected <- invalid do
      result = Validator.validate(rejected)
      assert result == {:error, :invalid_event}
      refute inspect(result) =~ "private"
    end
  end

  test "bounds collection size, key size, nesting depth, and aggregate bytes" do
    too_many_entries = Map.new(1..257, &{"key-#{&1}", &1})
    too_many_items = Enum.to_list(1..257)
    oversized_key = String.duplicate("k", 513)

    eight_levels =
      Enum.reduce(1..7, %{}, fn depth, nested -> %{"level-#{depth}" => nested} end)

    nine_levels =
      Enum.reduce(1..8, %{}, fn depth, nested -> %{"level-#{depth}" => nested} end)

    aggregate_overflow =
      Map.new(1..5, &{"key-#{&1}", String.duplicate("a", 16 * 1_024)})

    node_overflow = Map.new(1..256, &{"key-#{&1}", [nil, nil, nil, nil]})

    for facts <- [
          too_many_entries,
          %{"items" => too_many_items},
          %{oversized_key => true},
          nine_levels,
          aggregate_overflow,
          node_overflow
        ] do
      assert Validator.validate(event(facts: facts)) == {:error, :invalid_event}
    end

    assert Validator.validate(event(facts: eight_levels)) == :ok
  end

  test "matcher evaluation applies the shared bounded event boundary" do
    matcher = %ClusterMurmur.Events.Matcher{
      predicates: [
        %ClusterMurmur.Events.Matcher.Predicate{field: "type", operator: :exists}
      ]
    }

    oversized = event(facts: %{"payload" => String.duplicate("a", 16 * 1_024 + 1)})

    assert ClusterMurmur.Events.MatcherEvaluator.match(matcher, oversized) ==
             {:error, :invalid_event}
  end

  defp event(overrides) do
    struct!(
      Event,
      Keyword.merge(
        [
          id: "example-event",
          type: "observation.failed",
          source: "example-observer",
          subject: "example-target",
          group: "operations",
          severity: "warning",
          previous: nil,
          current: nil,
          occurred_at: ~U[2026-08-04 12:00:00Z],
          observed_at: nil,
          dedupe_key: nil,
          correlation_key: nil,
          facts: %{},
          labels: %{}
        ],
        overrides
      )
    )
  end
end

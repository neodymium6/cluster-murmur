defmodule ClusterMurmur.Events.MatcherEvaluatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Events.MatcherEvaluator

  @now ~U[2026-01-01 00:00:00Z]

  test "matches a conjunction across top-level, label, and fact fields" do
    matcher =
      matcher([
        predicate("type", :equals, "observation.failed"),
        predicate("source", :not_equals, "other-source"),
        membership("labels.category", ["monitoring", "storage"]),
        predicate("facts.attempts", :greater_than, 2),
        predicate("facts.latency", :less_than, 2.0),
        predicate("subject", :exists)
      ])

    assert MatcherEvaluator.match(matcher, event()) == {:ok, true}

    refute_match = %{event() | facts: %{"attempts" => 2, "latency" => 1.5}}
    assert MatcherEvaluator.match(matcher, refute_match) == {:ok, false}
  end

  test "requires every predicate in the conjunction to match" do
    matcher =
      matcher([
        predicate("type", :equals, "observation.failed"),
        predicate("severity", :equals, "warning")
      ])

    assert MatcherEvaluator.match(matcher, event()) == {:ok, true}
    assert MatcherEvaluator.match(matcher, %{event() | severity: "critical"}) == {:ok, false}
  end

  test "treats missing dynamic fields as non-matches for every operator" do
    predicates = [
      predicate("facts.missing", :equals, nil),
      predicate("facts.missing", :not_equals, "value"),
      membership("facts.missing", [nil, "value"]),
      predicate("facts.missing", :exists),
      predicate("facts.missing", :greater_than, 0),
      predicate("facts.missing", :less_than, 10)
    ]

    for predicate <- predicates do
      assert MatcherEvaluator.match(matcher([predicate]), event()) == {:ok, false}
    end
  end

  test "distinguishes null equality from non-null existence" do
    null_event = %{event() | facts: %{"nullable" => nil}}

    assert MatcherEvaluator.match(
             matcher([predicate("facts.nullable", :equals, nil)]),
             null_event
           ) == {:ok, true}

    assert MatcherEvaluator.match(
             matcher([predicate("facts.nullable", :exists)]),
             null_event
           ) == {:ok, false}
  end

  test "uses numeric equality while rejecting ordered comparisons for non-numbers" do
    numeric_event = %{event() | facts: %{"number" => 1, "text" => "10"}}

    assert MatcherEvaluator.match(
             matcher([predicate("facts.number", :equals, 1.0)]),
             numeric_event
           ) == {:ok, true}

    assert MatcherEvaluator.match(
             matcher([predicate("facts.text", :greater_than, 2)]),
             numeric_event
           ) == {:ok, false}
  end

  test "does not treat non-scalar fact values as unequal scalar matches" do
    compound_event = %{event() | facts: %{"compound" => %{"nested" => true}}}

    assert MatcherEvaluator.match(
             matcher([predicate("facts.compound", :not_equals, "value")]),
             compound_event
           ) == {:ok, false}

    assert MatcherEvaluator.match(
             matcher([predicate("facts.compound", :exists)]),
             compound_event
           ) == {:ok, true}
  end

  test "rejects forged matcher collections and duplicate predicates" do
    valid = predicate("type", :exists)

    invalid = [
      %Matcher{predicates: []},
      %Matcher{predicates: List.duplicate(valid, 33)},
      %Matcher{predicates: [valid | :tail]},
      %Matcher{predicates: [valid, valid]},
      %Matcher{predicates: [%{}]}
    ]

    for matcher <- invalid do
      assert MatcherEvaluator.match(matcher, event()) == {:error, :invalid_matcher}
    end
  end

  test "rejects forged fields, operators, and operand shapes" do
    invalid = [
      predicate("payload.value", :exists),
      predicate("facts.a.b", :exists),
      %Predicate{field: "type", operator: :matches, value: ".*"},
      %Predicate{field: "type", operator: :exists, value: true},
      %Predicate{field: "type", operator: :in, values: []},
      %Predicate{field: "type", operator: :in, values: [1, 1.0]},
      %Predicate{field: "type", operator: :greater_than, value: "2"},
      %Predicate{
        field: "type",
        operator: :equals,
        value: String.duplicate("a", 1_025)
      }
    ]

    for predicate <- invalid do
      assert MatcherEvaluator.match(matcher([predicate]), event()) ==
               {:error, :invalid_matcher}
    end
  end

  test "rejects forged event values without exposing their contents" do
    matcher = matcher([predicate("type", :exists)])

    invalid = [
      nil,
      %{},
      %{__struct__: Event},
      %{event() | facts: []},
      %{event() | labels: URI.parse("https://example.invalid")},
      %{event() | occurred_at: nil},
      %{event() | occurred_at: %{__struct__: DateTime}},
      %{event() | occurred_at: %{@now | hour: 99}},
      %{event() | occurred_at: %{@now | year: nil}},
      %{event() | occurred_at: %{@now | hour: :bad}},
      %{event() | occurred_at: %{@now | microsecond: nil}},
      %{event() | occurred_at: %{@now | microsecond: {1_000_000, 6}}},
      %{event() | observed_at: "later"},
      %{event() | observed_at: %{@now | month: nil}},
      %{event() | observed_at: %{@now | microsecond: nil}},
      %{event() | correlation_key: 123},
      %{event() | source: <<255>>}
    ]

    for event <- invalid do
      result = MatcherEvaluator.match(matcher, event)
      assert result == {:error, :invalid_event}
      refute inspect(result) =~ "example.invalid"
    end
  end

  test "classifies a forged non-matcher before the event" do
    assert MatcherEvaluator.match(%{}, nil) == {:error, :invalid_matcher}
  end

  defp matcher(predicates), do: %Matcher{predicates: predicates}

  defp predicate(field, :exists), do: %Predicate{field: field, operator: :exists}

  defp predicate(field, operator, value),
    do: %Predicate{field: field, operator: operator, value: value}

  defp membership(field, values),
    do: %Predicate{field: field, operator: :in, values: values}

  defp event do
    %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-source",
      subject: "example-target",
      group: "operations",
      severity: "warning",
      occurred_at: @now,
      labels: %{"category" => "monitoring"},
      facts: %{"attempts" => 3, "latency" => 1.5}
    }
  end
end

defmodule ClusterMurmur.Config.EventMatcherTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{EventMatcher, SchemaValidator}
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate

  test "validates and normalizes every version 1 operator" do
    document = %{
      "all" => [
        predicate("type", "equals", "observation.failed"),
        predicate("source", "not_equals", "example-source"),
        %{
          "field" => "labels.category",
          "operator" => "in",
          "values" => ["storage", "monitoring"]
        },
        %{"field" => "facts.attempts", "operator" => "greater_than", "value" => 2},
        %{"field" => "facts.latency", "operator" => "less_than", "value" => 1.5},
        %{"field" => "subject", "operator" => "exists"}
      ]
    }

    assert {:ok, %Matcher{predicates: predicates}} = EventMatcher.parse(document)
    assert length(predicates) == 6

    assert %Predicate{operator: :in, values: ["monitoring", "storage"]} =
             Enum.find(predicates, &(&1.operator == :in))

    assert Enum.all?(predicates, &match?(%Predicate{}, &1))
  end

  test "supports JSON scalar equality values including null" do
    for value <- [nil, true, false, 1, 1.5, "critical"] do
      assert {:ok, %Matcher{predicates: [%Predicate{value: ^value}]}} =
               EventMatcher.parse(%{"all" => [predicate("severity", "equals", value)]})
    end
  end

  test "reuses one compiled schema across matchers" do
    assert {:ok, validator} = EventMatcher.compile()
    first = %{"all" => [predicate("type", "equals", "observation.failed")]}
    second = %{"all" => [%{"field" => "subject", "operator" => "exists"}]}
    assert {:ok, %Matcher{}} = EventMatcher.parse(first, validator)
    assert {:ok, %Matcher{}} = EventMatcher.parse(second, validator)
  end

  test "does not trust a valid foreign compiled schema for matcher invariants" do
    assert {:ok, foreign_validator} =
             SchemaValidator.compile(%{
               "$schema" => "http://json-schema.org/draft-07/schema#",
               "type" => "object"
             })

    invalid_matchers = [
      %{},
      %{"all" => "not-a-list"},
      %{"all" => []},
      %{"all" => List.duplicate(%{"field" => "type", "operator" => "exists"}, 33)},
      %{"all" => [%{"field" => "type", "operator" => "in", "values" => Enum.to_list(1..33)}]},
      %{"all" => [nil]},
      %{"all" => [%{"field" => "type", "operator" => "exists"}], "extra" => true}
    ]

    for document <- invalid_matchers do
      assert EventMatcher.parse(document, foreign_validator) == {:error, :invalid_event_matcher}
    end
  end

  test "allows only bounded event fields" do
    valid = [
      "type",
      "source",
      "subject",
      "group",
      "severity",
      "labels.category",
      "labels.category_name",
      "facts.attempts",
      "facts.2nd-attempt"
    ]

    for field <- valid do
      assert {:ok, %Matcher{}} = EventMatcher.parse(%{"all" => [predicate(field, "equals", 1)]})
    end

    for field <- [
          "",
          "id",
          "labels",
          "labels.",
          "labels.invalid key",
          "facts.a.b",
          "payload.value",
          String.duplicate("a", 513)
        ] do
      assert EventMatcher.parse(%{"all" => [predicate(field, "equals", 1)]}) ==
               {:error, :invalid_event_matcher}
    end
  end

  test "requires each operator's exact value shape" do
    invalid = [
      %{"field" => "type", "operator" => "equals"},
      %{"field" => "type", "operator" => "equals", "value" => "x", "values" => ["x"]},
      %{"field" => "type", "operator" => "in", "value" => "x"},
      %{"field" => "type", "operator" => "in", "values" => []},
      %{"field" => "type", "operator" => "exists", "value" => true},
      %{"field" => "facts.count", "operator" => "greater_than", "value" => "2"},
      %{"field" => "facts.count", "operator" => "less_than", "value" => nil},
      %{"field" => "type", "operator" => "matches", "value" => ".*"}
    ]

    for predicate <- invalid do
      assert EventMatcher.parse(%{"all" => [predicate]}) == {:error, :invalid_event_matcher}
    end
  end

  test "accepts only bounded JSON scalar operands" do
    invalid_values = [
      %{},
      [],
      URI.parse("https://example.invalid"),
      String.duplicate("a", 1_025),
      <<255>>,
      self()
    ]

    for value <- invalid_values do
      assert EventMatcher.parse(%{"all" => [predicate("type", "equals", value)]}) ==
               {:error, :invalid_event_matcher}
    end
  end

  test "rejects duplicate predicates and duplicate membership values" do
    duplicate = predicate("type", "equals", "observation.failed")

    assert EventMatcher.parse(%{"all" => [duplicate, duplicate]}) ==
             {:error, :invalid_event_matcher}

    membership = %{"field" => "type", "operator" => "in", "values" => ["a", "a"]}
    assert EventMatcher.parse(%{"all" => [membership]}) == {:error, :invalid_event_matcher}

    numeric_membership = %{"field" => "type", "operator" => "in", "values" => [1, 1.0]}

    assert EventMatcher.parse(%{"all" => [numeric_membership]}) ==
             {:error, :invalid_event_matcher}
  end

  test "bounds predicates and membership lists" do
    predicates = Enum.map(1..32, &predicate("labels.key-#{&1}", "equals", &1))
    assert {:ok, %Matcher{predicates: normalized}} = EventMatcher.parse(%{"all" => predicates})
    assert length(normalized) == 32

    assert EventMatcher.parse(%{"all" => predicates ++ [predicate("type", "exists", nil)]}) ==
             {:error, :invalid_event_matcher}

    values = Enum.to_list(1..33)

    assert EventMatcher.parse(%{
             "all" => [%{"field" => "facts.value", "operator" => "in", "values" => values}]
           }) ==
             {:error, :invalid_event_matcher}
  end

  test "rejects malformed matcher roots and collections" do
    for document <- [nil, [], %{}, %{"all" => []}, %{"all" => [%{} | :tail]}, %{all: []}] do
      assert EventMatcher.parse(document) == {:error, :invalid_event_matcher}
    end
  end

  test "redacts matcher fields and operands from inspection" do
    assert {:ok, matcher} =
             EventMatcher.parse(%{
               "all" => [predicate("labels.private", "equals", "private-value")]
             })

    inspected = inspect(matcher)
    refute inspected =~ "private"
    refute inspected =~ "value"
    refute inspect(hd(matcher.predicates)) =~ "private"
  end

  defp predicate(field, "exists", _value), do: %{"field" => field, "operator" => "exists"}

  defp predicate(field, operator, value),
    do: %{"field" => field, "operator" => operator, "value" => value}
end

defmodule ClusterMurmur.Config.TriggersTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{LoadedDocument, Triggers}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Triggers.EventTrigger

  test "validates, normalizes, and combines event-trigger documents" do
    first =
      loaded(%{
        "triggers" => [
          trigger("monitoring-failure", "monitoring-characters", "30m", [
            predicate("type", "equals", "observation.failed"),
            predicate("labels.category", "in", ["storage", "monitoring"])
          ])
        ]
      })

    second =
      loaded(%{
        "triggers" => [
          trigger("recovery", "recovery-characters", "0ms", [
            predicate("type", "equals", "observation.recovered")
          ])
        ]
      })

    assert {:ok, %Triggers{triggers: triggers} = normalized} =
             Triggers.parse_documents([second, first])

    assert Triggers.parse_documents([first, second]) == {:ok, normalized}
    assert Map.keys(triggers) |> Enum.sort() == ["monitoring-failure", "recovery"]

    assert %EventTrigger{
             id: "monitoring-failure",
             action: :start_conversation,
             binding: "monitoring-characters",
             cooldown_ms: 1_800_000,
             matcher: %{predicates: predicates}
           } = triggers["monitoring-failure"]

    assert Enum.any?(predicates, &match?(%Predicate{operator: :equals}, &1))

    assert %Predicate{operator: :in, values: ["monitoring", "storage"]} =
             Enum.find(predicates, &(&1.operator == :in))
  end

  test "accepts an empty category and empty trigger lists" do
    assert Triggers.parse_documents([]) == {:ok, %Triggers{triggers: %{}}}

    assert Triggers.parse_documents([loaded(%{"triggers" => []})]) ==
             {:ok, %Triggers{triggers: %{}}}
  end

  test "rejects malformed and unsupported trigger shapes" do
    valid = trigger("monitoring", "characters", "30m", [predicate("type", "exists")])

    invalid_documents = [
      %{},
      %{"triggers" => %{}},
      %{"triggers" => [Map.put(valid, "extra", true)]},
      %{"triggers" => [Map.delete(valid, "event")]},
      %{"triggers" => [put_in(valid, ["event", "extra"], true)]},
      %{"triggers" => [put_in(valid, ["action", "extra"], true)]},
      %{"triggers" => [put_in(valid, ["action", "type"], "emit_event")]},
      %{"triggers" => [%{"id" => "daily", "schedule" => %{}, "action" => %{}}]},
      %{"triggers" => [%{"id" => "ambient", "stochastic" => %{}, "action" => %{}}]}
    ]

    for document <- invalid_documents do
      assert Triggers.parse_documents([loaded(document)]) == {:error, :invalid_trigger_document}
    end
  end

  test "validates IDs, cooldowns, and event matchers semantically" do
    invalid = [
      trigger("invalid id", "characters", "30m", [predicate("type", "exists")]),
      trigger("monitoring", "invalid binding", "30m", [predicate("type", "exists")]),
      trigger("monitoring", "characters", "later", [predicate("type", "exists")]),
      trigger("monitoring", "characters", "30m", [predicate("payload.value", "exists")]),
      trigger("monitoring", "characters", "30m", [
        %{"field" => "type", "operator" => "matches", "value" => ".*"}
      ])
    ]

    for attributes <- invalid do
      assert Triggers.parse_documents([loaded(%{"triggers" => [attributes]})]) ==
               {:error, :invalid_trigger_document}
    end
  end

  test "rejects duplicate trigger IDs across documents" do
    first = loaded(%{"triggers" => [trigger("same", "first", "1m")]})
    second = loaded(%{"triggers" => [trigger("same", "second", "2m")]})
    assert Triggers.parse_documents([first, second]) == {:error, :duplicate_trigger}
  end

  test "bounds the combined trigger category" do
    triggers = Enum.map(1..256, &trigger("trigger-#{&1}", "characters", "1m"))

    assert {:ok, %Triggers{triggers: parsed}} =
             Triggers.parse_documents([loaded(%{"triggers" => triggers})])

    assert map_size(parsed) == 256

    overflow_trigger = trigger("trigger-257", "characters", "1m")

    assert Triggers.parse_documents([loaded(%{"triggers" => triggers ++ [overflow_trigger]})]) ==
             {:error, :too_many_triggers}

    overflow = loaded(%{"triggers" => [overflow_trigger]})

    assert Triggers.parse_documents([loaded(%{"triggers" => triggers}), overflow]) ==
             {:error, :too_many_triggers}
  end

  test "rejects invalid document collections and improper trigger lists" do
    assert Triggers.parse_documents(nil) == {:error, :invalid_trigger_document}
    assert Triggers.parse_documents([%{}]) == {:error, :invalid_trigger_document}

    assert Triggers.parse_documents([loaded(%{"triggers" => []}) | :tail]) ==
             {:error, :invalid_trigger_document}

    assert Triggers.parse_documents([loaded(%{"triggers" => [%{} | :tail]})]) ==
             {:error, :invalid_trigger_document}
  end

  test "redacts trigger configuration from inspection" do
    trigger = %EventTrigger{
      id: "private-trigger",
      matcher: %ClusterMurmur.Events.Matcher{predicates: []},
      action: :start_conversation,
      binding: "private-binding",
      cooldown_ms: 1_000
    }

    set = %Triggers{triggers: %{"private-trigger" => trigger}}

    for inspected <- [inspect(trigger), inspect(set)] do
      refute inspected =~ "private"
      refute inspected =~ "binding"
    end
  end

  defp loaded(document), do: %LoadedDocument{path: "/config/triggers.yaml", document: document}

  defp trigger(id, binding, cooldown, predicates \\ [predicate("type", "exists")]) do
    %{
      "id" => id,
      "event" => %{"match" => %{"all" => predicates}},
      "action" => %{"type" => "start_conversation", "binding" => binding},
      "cooldown" => cooldown
    }
  end

  defp predicate(field, operator), do: %{"field" => field, "operator" => operator}

  defp predicate(field, "in", values),
    do: %{"field" => field, "operator" => "in", "values" => values}

  defp predicate(field, operator, value),
    do: %{"field" => field, "operator" => operator, "value" => value}
end

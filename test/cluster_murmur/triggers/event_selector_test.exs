defmodule ClusterMurmur.Triggers.EventSelectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Triggers.{EventSelector, EventTrigger}

  @now ~U[2026-01-01 00:00:00Z]

  test "selects matching triggers in deterministic ID order" do
    triggers = [
      trigger("z-recovery", predicate("type", :equals, "observation.recovered")),
      trigger("b-failure", predicate("severity", :equals, "warning")),
      trigger("a-failure", predicate("type", :equals, "observation.failed"))
    ]

    assert {:ok, selected} = EventSelector.select(triggers, event())
    assert Enum.map(selected, & &1.id) == ["a-failure", "b-failure"]

    assert EventSelector.select(Enum.reverse(triggers), event()) == {:ok, selected}
  end

  test "accepts an empty trigger collection without inspecting the event" do
    assert EventSelector.select([], nil) == {:ok, []}
  end

  test "rejects duplicate trigger IDs" do
    triggers = [
      trigger("same", predicate("type", :exists)),
      trigger("same", predicate("severity", :exists))
    ]

    assert EventSelector.select(triggers, event()) == {:error, :duplicate_trigger}
  end

  test "bounds trigger collections" do
    triggers = Enum.map(1..256, &trigger("trigger-#{&1}", predicate("type", :exists)))
    assert {:ok, selected} = EventSelector.select(triggers, event())
    assert length(selected) == 256

    assert EventSelector.select(
             triggers ++ [trigger("trigger-257", predicate("type", :exists))],
             event()
           ) == {:error, :too_many_triggers}
  end

  test "rejects malformed trigger domain values" do
    valid = trigger("valid", predicate("type", :exists))

    invalid = [
      nil,
      %{},
      %{__struct__: EventTrigger},
      %{valid | id: "invalid id"},
      %{valid | binding: "invalid binding"},
      %{valid | action: :emit_event},
      %{valid | cooldown_ms: -1},
      %{valid | matcher: %{}},
      Map.put(valid, :unexpected_private_value, "private")
    ]

    for trigger <- invalid do
      assert EventSelector.select([trigger], event()) == {:error, :invalid_trigger}
    end

    assert EventSelector.select([valid | :tail], event()) == {:error, :invalid_trigger}
  end

  test "classifies invalid nested matchers and events" do
    invalid_matcher = %Matcher{predicates: []}

    assert EventSelector.select([trigger("invalid", invalid_matcher)], event()) ==
             {:error, :invalid_trigger_matcher}

    forged_matcher = Map.put(trigger("valid", predicate("type", :exists)).matcher, :extra, true)

    assert EventSelector.select([trigger("invalid", forged_matcher)], event()) ==
             {:error, :invalid_trigger_matcher}

    assert EventSelector.select([trigger("valid", predicate("type", :exists))], nil) ==
             {:error, :invalid_event}
  end

  test "does not apply cooldown or execute selected actions" do
    trigger = %{trigger("cooling-down", predicate("type", :exists)) | cooldown_ms: 86_400_000}

    assert EventSelector.select([trigger], event()) == {:ok, [trigger]}
  end

  defp trigger(id, %Matcher{} = matcher) do
    %EventTrigger{
      id: id,
      matcher: matcher,
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: 60_000
    }
  end

  defp trigger(id, predicate), do: trigger(id, %Matcher{predicates: [predicate]})

  defp predicate(field, :exists), do: %Predicate{field: field, operator: :exists}

  defp predicate(field, operator, value),
    do: %Predicate{field: field, operator: operator, value: value}

  defp event do
    %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-source",
      severity: "warning",
      occurred_at: @now
    }
  end
end

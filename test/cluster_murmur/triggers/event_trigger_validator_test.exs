defmodule ClusterMurmur.Triggers.EventTriggerValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerValidator}

  test "accepts one exact bounded runtime event trigger" do
    assert EventTriggerValidator.validate(trigger()) == :ok
  end

  test "rejects malformed and forged outer trigger shapes" do
    valid = trigger()
    forged = Map.put(valid, :unexpected_private_value, String.duplicate("x", 1024 * 1024))

    for invalid <- [
          nil,
          %{},
          %{__struct__: EventTrigger},
          %{valid | id: "invalid id"},
          %{valid | binding: "invalid binding"},
          %{valid | action: :emit_event},
          %{valid | cooldown_ms: -1},
          %{valid | matcher: %{}},
          forged
        ] do
      result = EventTriggerValidator.validate(invalid)
      assert result == {:error, :invalid_trigger}
      refute inspect(result) =~ "private"
    end
  end

  test "rejects invalid and forged nested matcher shapes distinctly" do
    valid_matcher = trigger().matcher
    valid_predicate = hd(valid_matcher.predicates)

    too_many_predicates =
      Enum.map(1..33, &%Predicate{field: "type", operator: :equals, value: &1})

    too_many_values = %Predicate{field: "type", operator: :in, values: Enum.to_list(1..33)}

    invalid_matchers = [
      %Matcher{predicates: []},
      %Matcher{predicates: [valid_predicate | :improper_tail]},
      %Matcher{predicates: too_many_predicates},
      %Matcher{predicates: [too_many_values]},
      Map.put(valid_matcher, :unexpected_private_value, "private"),
      %Matcher{predicates: [Map.put(valid_predicate, :unexpected_private_value, "private")]}
    ]

    for matcher <- invalid_matchers do
      result = EventTriggerValidator.validate(%{trigger() | matcher: matcher})
      assert result == {:error, :invalid_trigger_matcher}
      refute inspect(result) =~ "private"
    end
  end

  defp trigger do
    %EventTrigger{
      id: "example-trigger",
      matcher: %Matcher{
        predicates: [%Predicate{field: "type", operator: :equals, value: "observation.failed"}]
      },
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: 60_000
    }
  end
end

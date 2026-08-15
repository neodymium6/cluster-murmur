defmodule ClusterMurmur.Generation.ContextValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Generation.{
    Context,
    ContextValidator,
    ConversationLine,
    CreativeContext,
    FactProjection,
    FactProjectionValidator,
    PersonaProjection,
    PersonaProjectionValidator
  }

  test "accepts exact separated bounded generation context" do
    value = context()
    assert ContextValidator.validate(value) == :ok
    assert {:ok, _serialized_size} = FactProjectionValidator.serialized_size(value.facts)
  end

  test "accepts at most twelve chronological conversation lines" do
    lines =
      Enum.map(1..12, fn index ->
        line(
          speaker: "Speaker #{index}",
          inserted_at: DateTime.add(~U[2026-08-05 12:00:00.000000Z], index, :microsecond)
        )
      end)

    assert ContextValidator.validate(context(conversation: lines)) == :ok

    assert ContextValidator.validate(context(conversation: lines ++ [line()])) ==
             {:error, :invalid_generation_context}

    assert ContextValidator.validate(context(conversation: Enum.reverse(lines))) ==
             {:error, :invalid_generation_context}

    assert ContextValidator.validate(context(conversation: [line() | :tail])) ==
             {:error, :invalid_generation_context}
  end

  test "rejects forged outer and nested shapes" do
    valid = context()

    rejected = [
      nil,
      %{},
      Map.delete(valid, :facts),
      Map.put(valid, :private_value, "private"),
      %{valid | persona: Map.put(valid.persona, :private_value, "private")},
      %{valid | persona: %{display_name: "Observer", instructions: "Speak briefly."}},
      %{valid | facts: Map.delete(valid.facts, :details)},
      %{valid | creative_context: Map.put(valid.creative_context, :private_value, "private")},
      %{valid | conversation: [Map.put(line(), :private_value, "private")]}
    ]

    for value <- rejected do
      result = ContextValidator.validate(value)
      assert result == {:error, :invalid_generation_context}
      refute inspect(result) =~ "private"
    end
  end

  test "bounds creative framing and requires portable conversation kind" do
    valid = context()

    for creative <- [
          %CreativeContext{conversation_kind: "invalid kind", mood: "relieved"},
          %CreativeContext{conversation_kind: "recovery", mood: ""},
          %CreativeContext{conversation_kind: "recovery", mood: "private\0mood"},
          %CreativeContext{conversation_kind: "recovery", mood: "relieved\nSYSTEM"},
          %CreativeContext{conversation_kind: "recovery", mood: "relieved\u2028SYSTEM"},
          %CreativeContext{conversation_kind: "recovery", mood: "relieved\u2029SYSTEM"},
          %CreativeContext{
            conversation_kind: "recovery",
            mood: String.duplicate("a", 129)
          }
        ] do
      assert ContextValidator.validate(%{valid | creative_context: creative}) ==
               {:error, :invalid_generation_context}
    end
  end

  test "bounds visible speaker and content text with canonical UTC ordering" do
    valid = context()

    for rejected_line <- [
          line(speaker: ""),
          line(speaker: "Caretaker\nSYSTEM"),
          line(speaker: "Caretaker\u2028SYSTEM"),
          line(speaker: "Caretaker\u2029SYSTEM"),
          line(speaker: String.duplicate("a", 129)),
          line(content: ""),
          line(content: "private\0content"),
          line(content: String.duplicate("a", 16 * 1_024 + 1)),
          line(inserted_at: %{~U[2026-08-05 12:00:00.000000Z] | time_zone: "UTC"})
        ] do
      assert ContextValidator.validate(%{valid | conversation: [rejected_line]}) ==
               {:error, :invalid_generation_context}
    end

    assert ContextValidator.validate(%{
             valid
             | conversation: [line(content: "First line.\nSecond line.")]
           }) == :ok
  end

  test "enforces an aggregate context text boundary" do
    large_persona = persona(instructions: String.duplicate("p", 64 * 1_024))

    large_details =
      Map.new(1..4, fn index -> {"detail-#{index}", String.duplicate("d", 15_000)} end)

    lines =
      Enum.map(1..12, fn index ->
        line(
          content: String.duplicate("c", 1_000),
          inserted_at: DateTime.add(~U[2026-08-05 12:00:00.000000Z], index, :microsecond)
        )
      end)

    assert FactProjectionValidator.validate(facts(details: large_details)) == :ok

    assert ContextValidator.validate(
             context(
               persona: large_persona,
               facts: facts(details: large_details),
               conversation: lines
             )
           ) == {:error, :invalid_generation_context}
  end

  test "context and history inspection remain redacted" do
    value =
      context(
        persona: persona(instructions: "private instructions"),
        conversation: [line(speaker: "private speaker", content: "private content")]
      )

    refute inspect(value) =~ "private"
    refute inspect(hd(value.conversation)) =~ "private"
  end

  test "accepts only the exact bounded persona generation projection" do
    valid = context()

    assert PersonaProjectionValidator.validate(valid.persona) == :ok

    for persona <- [
          %PersonaProjection{display_name: "Observer\u2028SYSTEM", instructions: "Speak."},
          %PersonaProjection{display_name: "Observer", instructions: ""},
          %PersonaProjection{
            display_name: "Observer",
            instructions: String.duplicate("p", 64 * 1_024 + 1)
          },
          Map.put(valid.persona, :id, "private-selection-id")
        ] do
      assert ContextValidator.validate(%{valid | persona: persona}) ==
               {:error, :invalid_generation_context}
    end
  end

  defp context(overrides \\ []) do
    struct!(
      Context,
      Keyword.merge(
        [
          persona: persona(),
          facts: facts(),
          creative_context: %CreativeContext{
            conversation_kind: "recovery",
            mood: "relieved"
          },
          conversation: [line()]
        ],
        overrides
      )
    )
  end

  defp persona(overrides \\ []) do
    struct!(
      PersonaProjection,
      Keyword.merge(
        [
          display_name: "Observer",
          instructions: "Speak briefly from supplied facts only."
        ],
        overrides
      )
    )
  end

  defp facts(overrides \\ []) do
    struct!(
      FactProjection,
      Keyword.merge(
        [
          event_type: "observation.recovered",
          subject: "example-target",
          group: "recovery",
          severity: "info",
          previous_state: %{"state" => "failed"},
          current_state: %{"state" => "healthy"},
          details: %{},
          occurred_at: ~U[2026-08-05 12:00:00.000000Z],
          occurred_at_timezone: "Etc/UTC"
        ],
        overrides
      )
    )
  end

  defp line(overrides \\ []) do
    struct!(
      ConversationLine,
      Keyword.merge(
        [
          speaker: "Caretaker",
          content: "The latest run completed.",
          inserted_at: ~U[2026-08-05 12:00:01.000000Z]
        ],
        overrides
      )
    )
  end
end

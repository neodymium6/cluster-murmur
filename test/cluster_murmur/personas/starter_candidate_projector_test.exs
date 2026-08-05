defmodule ClusterMurmur.Personas.StarterCandidateProjectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.PersonaCooldownRecord

  alias ClusterMurmur.Personas.{
    Binding,
    Persona,
    StarterCandidate,
    StarterCandidateProjector
  }

  @now ~U[2026-08-05 12:00:00.000000Z]

  test "projects configured weight components in stable persona order" do
    binding =
      binding_value([
        %{persona: "zeta", weight: 2},
        %{persona: "alpha", weight: 1.5}
      ])

    personas = %{
      "zeta" => persona("zeta", interests: %{"operations" => 3}),
      "alpha" =>
        persona("alpha",
          interests: %{"operations" => 0.5},
          behavior: %{"spontaneous_weight" => 4}
        )
    }

    assert {:ok,
            [
              %StarterCandidate{
                persona_id: "alpha",
                binding_weight: 1.5,
                interest_weight: 0.5,
                spontaneous_weight: 4,
                weight: 6.0
              },
              %StarterCandidate{
                persona_id: "zeta",
                binding_weight: 2,
                interest_weight: 3,
                spontaneous_weight: 0,
                weight: 5
              }
            ]} = StarterCandidateProjector.project(binding, personas, %{}, @now)
  end

  test "excludes disabled personas and personas whose cooldown is active" do
    binding = binding_value([candidate("disabled"), candidate("active"), candidate("deadline")])

    personas = %{
      "disabled" => persona("disabled", enabled: false),
      "active" => persona("active"),
      "deadline" => persona("deadline")
    }

    cooldowns = %{
      "active" => cooldown("active", DateTime.add(@now, 1, :microsecond)),
      "deadline" => cooldown("deadline", @now)
    }

    assert {:ok, [%StarterCandidate{persona_id: "deadline"}]} =
             StarterCandidateProjector.project(binding, personas, cooldowns, @now)
  end

  test "preserves eligible zero-weight candidates for the selector" do
    binding = binding_value([candidate("observer", 0)])
    personas = %{"observer" => persona("observer")}

    assert {:ok, [%StarterCandidate{persona_id: "observer", weight: 0}]} =
             StarterCandidateProjector.project(binding, personas, %{}, @now)
  end

  test "rejects missing persona references after validating the catalog" do
    assert StarterCandidateProjector.project(
             binding_value([candidate("missing")]),
             %{},
             %{},
             @now
           ) ==
             {:error, :unknown_persona}
  end

  test "rejects malformed runtime capabilities without exposing values" do
    valid_binding = binding_value([candidate("private-persona")])
    valid_personas = %{"private-persona" => persona("private-persona")}

    rejected = [
      {nil, valid_personas, %{}, @now, :invalid_binding},
      {%{
         valid_binding
         | candidates: [candidate("private-persona"), candidate("private-persona")]
       }, valid_personas, %{}, @now, :duplicate_binding_candidate},
      {valid_binding, [], %{}, @now, :invalid_persona_collection},
      {valid_binding, %{private: persona("private-persona")}, %{}, @now,
       :invalid_persona_collection},
      {valid_binding, valid_personas, [], @now, :invalid_persona_cooldown_collection},
      {valid_binding, valid_personas, %{"private-persona" => %PersonaCooldownRecord{}}, @now,
       :invalid_persona_cooldown_record},
      {valid_binding, valid_personas, %{}, %{@now | time_zone: "UTC"}, :invalid_datetime}
    ]

    for {binding, personas, cooldowns, now, reason} <- rejected do
      result = StarterCandidateProjector.project(binding, personas, cooldowns, now)
      assert result == {:error, reason}
      refute inspect(result) =~ "private"
    end
  end

  test "rejects forged cooldown keys and bounded collection overflow" do
    valid_binding = binding_value([candidate("observer")])
    valid_personas = %{"observer" => persona("observer")}
    record = cooldown("observer", @now)

    assert StarterCandidateProjector.project(
             valid_binding,
             valid_personas,
             %{"different" => record},
             @now
           ) == {:error, :invalid_persona_cooldown_record}

    oversized_personas = Map.new(1..257, &{"persona-#{&1}", persona("persona-#{&1}")})

    assert StarterCandidateProjector.project(valid_binding, oversized_personas, %{}, @now) ==
             {:error, :invalid_persona_collection}

    oversized_cooldowns =
      Map.new(1..257, fn index ->
        id = "persona-#{index}"
        {id, cooldown(id, @now)}
      end)

    assert StarterCandidateProjector.project(
             valid_binding,
             valid_personas,
             oversized_cooldowns,
             @now
           ) == {:error, :invalid_persona_cooldown_collection}
  end

  test "rejects a total weight that exceeds the numeric boundary" do
    binding = binding_value([candidate("observer", 1.7976931348623157e308)])

    personas = %{
      "observer" => persona("observer", interests: %{"operations" => 1.7976931348623157e308})
    }

    assert StarterCandidateProjector.project(binding, personas, %{}, @now) ==
             {:error, :invalid_candidate_weight}
  end

  test "candidate inspection remains redacted" do
    {:ok, [candidate]} =
      StarterCandidateProjector.project(
        binding_value([candidate("private-persona")]),
        %{"private-persona" => persona("private-persona")},
        %{},
        @now
      )

    refute inspect(candidate) =~ "private"
  end

  defp binding_value(candidates) do
    %Binding{id: "operations-characters", group: "operations", candidates: candidates}
  end

  defp candidate(persona_id, weight \\ 1), do: %{persona: persona_id, weight: weight}

  defp persona(id, overrides \\ []) do
    struct!(
      Persona,
      Keyword.merge(
        [
          id: id,
          display_name: "Observer",
          avatar: nil,
          prompt: "Report supplied facts only.",
          enabled: true,
          interests: %{},
          behavior: %{},
          relationships: %{},
          metadata: %{}
        ],
        overrides
      )
    )
  end

  defp cooldown(persona_id, cooldown_until) do
    %PersonaCooldownRecord{
      persona_id: persona_id,
      last_spoken_at: DateTime.add(cooldown_until, -1, :second),
      cooldown_until: cooldown_until
    }
    |> Ecto.put_meta(state: :loaded)
  end
end

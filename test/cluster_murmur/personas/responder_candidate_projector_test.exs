defmodule ClusterMurmur.Personas.ResponderCandidateProjectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.{Budget, Conversation}
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Persistence.PersonaCooldownRecord

  alias ClusterMurmur.Personas.{
    Binding,
    Persona,
    ResponderCandidate,
    ResponderCandidateProjector,
    ResponderPolicy
  }

  @now ~U[2026-08-05 12:01:00.000000Z]

  test "projects configured responder weights in stable persona order" do
    binding =
      binding_value([
        candidate("zeta", 2),
        candidate("alpha", 1)
      ])

    personas = %{
      "zeta" => persona("zeta", interests: %{"operations" => 1}),
      "alpha" =>
        persona("alpha",
          interests: %{"operations" => 2},
          behavior: %{"reply_weight" => 3}
        )
    }

    assert {:ok,
            [
              %ResponderCandidate{
                persona_id: "alpha",
                binding_weight: 1,
                interest_weight: 2,
                relationship_weight: 0,
                reply_weight: 3,
                weight: 6
              },
              %ResponderCandidate{persona_id: "zeta", weight: 3}
            ]} =
             project(binding, personas, %{}, conversation(), budget(), @now, policy())
  end

  test "excludes disabled, irrelevant, cooled down, and continuity-blocked personas" do
    ids = ["disabled", "irrelevant", "cooldown", "observer", "returning", "new"]
    binding = binding_value(Enum.map(ids, &candidate/1))

    personas = %{
      "disabled" => persona("disabled", enabled: false, interests: relevant()),
      "irrelevant" => persona("irrelevant"),
      "cooldown" => persona("cooldown", interests: relevant()),
      "observer" => persona("observer", interests: relevant()),
      "returning" => persona("returning", interests: relevant()),
      "new" => persona("new", interests: relevant())
    }

    cooldowns = %{"cooldown" => cooldown("cooldown", DateTime.add(@now, 1, :microsecond))}
    conversation = conversation(participants: ["observer", "returning"])

    assert project(binding, personas, cooldowns, conversation, budget(), @now, policy()) ==
             {:ok, []}
  end

  test "allows configured consecutive speech and participant reentry at a full participant limit" do
    binding = binding_value([candidate("observer"), candidate("returning")])

    personas = %{
      "observer" => persona("observer", interests: relevant()),
      "returning" => persona("returning", interests: relevant())
    }

    conversation = conversation(participants: ["observer", "returning"])
    policy = policy(allow_same_persona_consecutively: true, allow_persona_reentry: true)

    assert {:ok,
            [
              %ResponderCandidate{persona_id: "observer"},
              %ResponderCandidate{persona_id: "returning"}
            ]} = project(binding, personas, %{}, conversation, budget(), @now, policy)
  end

  test "allows a new participant only while a participant slot remains" do
    binding = binding_value([candidate("new")])
    personas = %{"new" => persona("new", interests: relevant())}

    assert {:ok, [%ResponderCandidate{persona_id: "new"}]} =
             project(binding, personas, %{}, conversation(), budget(), @now, policy())

    assert project(
             binding,
             personas,
             %{},
             conversation(participants: ["observer", "returning"]),
             budget(),
             @now,
             policy()
           ) == {:ok, []}
  end

  test "returns no responders when a core conversation budget is exhausted" do
    binding = binding_value([candidate("new")])
    personas = %{"new" => persona("new", interests: relevant())}

    assert project(
             binding,
             personas,
             %{},
             conversation(turn_count: 3),
             budget(),
             @now,
             policy()
           ) == {:ok, []}
  end

  test "treats the exact cooldown deadline as eligible" do
    binding = binding_value([candidate("new")])
    personas = %{"new" => persona("new", interests: relevant())}
    cooldowns = %{"new" => cooldown("new", @now)}

    assert {:ok, [%ResponderCandidate{persona_id: "new"}]} =
             project(binding, personas, cooldowns, conversation(), budget(), @now, policy())
  end

  test "rejects malformed capabilities and conversations without a previous speaker" do
    binding = binding_value([candidate("private-persona")])
    personas = %{"private-persona" => persona("private-persona", interests: relevant())}

    rejected = [
      {nil, personas, %{}, conversation(), budget(), @now, policy(), :invalid_binding},
      {binding, [], %{}, conversation(), budget(), @now, policy(), :invalid_persona_collection},
      {binding, personas, [], conversation(), budget(), @now, policy(),
       :invalid_persona_cooldown_collection},
      {binding, personas, %{}, conversation(messages: [], last_message_at: nil), budget(), @now,
       policy(), :missing_previous_speaker},
      {binding, personas, %{}, conversation(), nil, @now, policy(), :invalid_conversation_budget},
      {binding, personas, %{}, conversation(), budget(), %{@now | time_zone: "UTC"}, policy(),
       :invalid_datetime},
      {binding, personas, %{}, conversation(), budget(), @now, nil, :invalid_responder_policy}
    ]

    for {binding, personas, cooldowns, conversation, budget, now, policy, reason} <- rejected do
      result = project(binding, personas, cooldowns, conversation, budget, now, policy)
      assert result == {:error, reason}
      refute inspect(result) =~ "private"
    end
  end

  test "rejects unknown persona references and overflowing configured weights" do
    assert project(
             binding_value([candidate("missing")]),
             %{},
             %{},
             conversation(),
             budget(),
             @now,
             policy()
           ) == {:error, :unknown_persona}

    binding = binding_value([candidate("overflow", 1.7976931348623157e308)])

    personas = %{
      "overflow" =>
        persona("overflow",
          interests: %{"operations" => 1.7976931348623157e308}
        )
    }

    assert project(binding, personas, %{}, conversation(), budget(), @now, policy()) ==
             {:error, :invalid_candidate_weight}
  end

  test "responder candidate inspection remains redacted" do
    {:ok, [candidate]} =
      project(
        binding_value([candidate("private-persona")]),
        %{"private-persona" => persona("private-persona", interests: relevant())},
        %{},
        conversation(),
        budget(),
        @now,
        policy()
      )

    refute inspect(candidate) =~ "private"
  end

  defp project(binding, personas, cooldowns, conversation, budget, now, policy) do
    ResponderCandidateProjector.project(
      binding,
      personas,
      cooldowns,
      conversation,
      budget,
      now,
      policy
    )
  end

  defp binding_value(candidates) do
    %Binding{id: "operations-characters", group: "operations", candidates: candidates}
  end

  defp candidate(persona_id, weight \\ 1), do: %{persona: persona_id, weight: weight}
  defp relevant, do: %{"operations" => 1}

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

  defp conversation(overrides \\ []) do
    last_message = message("observer", @now)

    struct!(
      Conversation,
      Keyword.merge(
        [
          id: "conversation-1",
          root_event_id: "event-1",
          status: :waiting,
          started_at: ~U[2026-08-05 12:00:00.000000Z],
          last_message_at: @now,
          turn_count: 1,
          llm_call_count: 1,
          participants: ["observer"],
          messages: [last_message]
        ],
        overrides
      )
    )
  end

  defp message(persona_id, inserted_at) do
    %Message{
      conversation_id: "conversation-1",
      persona_id: persona_id,
      origin: :llm,
      content: "A bounded fact.",
      discord_message_id: nil,
      inserted_at: inserted_at
    }
  end

  defp budget do
    %Budget{
      max_turns: 3,
      max_participants: 2,
      max_duration_ms: 300_000,
      max_llm_calls: 3
    }
  end

  defp policy(overrides \\ []) do
    struct!(
      ResponderPolicy,
      Keyword.merge(
        [allow_same_persona_consecutively: false, allow_persona_reentry: false],
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

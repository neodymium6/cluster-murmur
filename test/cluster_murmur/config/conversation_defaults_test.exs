defmodule ClusterMurmur.Config.ConversationDefaultsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ConversationDefaults
  alias ClusterMurmur.Conversations.Budget
  alias ClusterMurmur.Personas.ResponderPolicy

  test "returns and projects the fixed version 1 defaults" do
    defaults = ConversationDefaults.default()

    assert defaults == %ConversationDefaults{
             max_turns: 3,
             max_participants: 2,
             max_duration_ms: 300_000,
             max_llm_calls: 3,
             allow_same_persona_consecutively: false,
             allow_persona_reentry: true,
             no_reply_weight: 1.0,
             random_jitter: 0.2
           }

    assert ConversationDefaults.validate(defaults) == :ok

    assert ConversationDefaults.to_budget(defaults) ==
             {:ok,
              %Budget{
                max_turns: 3,
                max_participants: 2,
                max_duration_ms: 300_000,
                max_llm_calls: 3
              }}

    assert ConversationDefaults.to_responder_policy(defaults) ==
             {:ok,
              %ResponderPolicy{
                allow_same_persona_consecutively: false,
                allow_persona_reentry: true
              }}

    assert {:ok, document} = ConversationDefaults.to_document(defaults)
    assert ConversationDefaults.parse(document) == {:ok, defaults}
  end

  test "parses one exact explicit mapping" do
    assert ConversationDefaults.parse(document()) ==
             {:ok,
              %ConversationDefaults{
                max_turns: 5,
                max_participants: 4,
                max_duration_ms: 90_000,
                max_llm_calls: 6,
                allow_same_persona_consecutively: true,
                allow_persona_reentry: false,
                no_reply_weight: 2.5,
                random_jitter: 0.4
              }}
  end

  test "rejects incomplete, extended, and out-of-range mappings" do
    invalid = [
      nil,
      [],
      Map.delete(document(), "max_turns"),
      Map.put(document(), "private", true),
      put_in(document()["responder_selection"], %{"no_reply_weight" => 1.0}),
      put_in(document()["responder_selection"]["private"], true),
      Map.put(document(), "max_turns", 0),
      Map.put(document(), "max_participants", 257),
      Map.put(document(), "max_duration", "0ms"),
      Map.put(document(), "max_llm_calls", 1.0),
      Map.put(document(), "allow_persona_reentry", :private),
      put_in(document()["responder_selection"]["no_reply_weight"], 0),
      put_in(document()["responder_selection"]["random_jitter"], 1.1)
    ]

    for value <- invalid do
      assert ConversationDefaults.parse(value) ==
               {:error, :invalid_conversation_defaults}
    end
  end

  test "rejects forged normalized values and projections fail closed" do
    valid = ConversationDefaults.default()

    for forged <- [
          nil,
          Map.put(valid, :private, true),
          %{valid | max_turns: 0},
          %{valid | max_participants: 257},
          %{valid | max_duration_ms: 31_536_000_001},
          %{valid | max_llm_calls: 0},
          %{valid | allow_same_persona_consecutively: nil},
          %{valid | allow_persona_reentry: nil},
          %{valid | no_reply_weight: 0},
          %{valid | random_jitter: -0.1}
        ] do
      assert ConversationDefaults.validate(forged) ==
               {:error, :invalid_conversation_defaults}

      assert ConversationDefaults.to_budget(forged) ==
               {:error, :invalid_conversation_defaults}

      assert ConversationDefaults.to_responder_policy(forged) ==
               {:error, :invalid_conversation_defaults}

      assert ConversationDefaults.to_document(forged) ==
               {:error, :invalid_conversation_defaults}
    end
  end

  defp document do
    %{
      "max_turns" => 5,
      "max_participants" => 4,
      "max_duration" => "90s",
      "max_llm_calls" => 6,
      "allow_same_persona_consecutively" => true,
      "allow_persona_reentry" => false,
      "responder_selection" => %{
        "no_reply_weight" => 2.5,
        "random_jitter" => 0.4
      }
    }
  end
end

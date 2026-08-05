defmodule ClusterMurmur.Personas.ValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Personas.{Persona, Validator}

  test "accepts exact bounded runtime personas" do
    assert Validator.validate(persona([])) == :ok

    assert Validator.validate(
             persona(
               avatar: "https://example.com/avatar.png",
               interests: %{"operations" => 1.5},
               behavior: %{
                 "cooldown_ms" => 365 * 86_400_000,
                 "reply_weight" => 0.8,
                 "spontaneous_weight" => 0
               }
             )
           ) == :ok
  end

  test "rejects malformed identities, prompts, and closed runtime shape" do
    valid = persona([])

    for rejected <- [
          nil,
          %{},
          %{valid | id: "invalid id"},
          %{valid | display_name: "   "},
          %{valid | display_name: String.duplicate("a", 129)},
          %{valid | prompt: ""},
          %{valid | prompt: <<255>>},
          %{valid | enabled: nil},
          Map.delete(valid, :prompt),
          Map.put(valid, :unexpected_private_value, "private")
        ] do
      result = Validator.validate(rejected)
      assert result == {:error, :invalid_persona}
      refute inspect(result) =~ "private"
    end
  end

  test "rejects unsafe avatar projections" do
    for avatar <- [
          "",
          "http://example.com/avatar.png",
          "https://user@example.com/avatar.png",
          "https://",
          "https://example.com/%ZZ",
          <<"https://example.com/", 255>>,
          String.duplicate("a", 2_049)
        ] do
      assert Validator.validate(persona(avatar: avatar)) == {:error, :invalid_persona}
    end
  end

  test "bounds interests and normalized behavior" do
    too_many_interests = Map.new(1..257, &{"group-#{&1}", 1})

    for rejected <- [
          persona(interests: too_many_interests),
          persona(interests: %{"invalid id" => 1}),
          persona(interests: %{"operations" => -1}),
          persona(behavior: %{"cooldown_ms" => -1}),
          persona(behavior: %{"cooldown_ms" => 365 * 86_400_000 + 1}),
          persona(behavior: %{"reply_weight" => -1}),
          persona(behavior: %{"cooldown" => "30m"}),
          persona(behavior: %{"unknown" => true}),
          persona(relationships: %{"other" => 1}),
          persona(metadata: %{"private" => true})
        ] do
      assert Validator.validate(rejected) == {:error, :invalid_persona}
    end
  end

  test "redacted persona inspection remains unchanged" do
    value =
      persona(
        id: "private-persona",
        display_name: "Private Persona",
        prompt: "private prompt"
      )

    assert Validator.validate(value) == :ok
    refute inspect(value) =~ "private"
  end

  defp persona(overrides) do
    struct!(
      Persona,
      Keyword.merge(
        [
          id: "observer",
          display_name: "Observer",
          avatar: nil,
          prompt: "Speak only from supplied facts.",
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
end

defmodule ClusterMurmur.Config.ManifestTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{
    ConversationDefaults,
    DocumentDecoder,
    EventPolicy,
    LLM,
    Manifest,
    StateTracking
  }

  test "accepts the bounded decoder output" do
    yaml = """
    version: 1
    llm:
      provider: openai_compatible
      base_url_env: LLM_BASE_URL
      model_env: LLM_MODEL
      api_key_file_env: LLM_API_KEY_FILE
      timeout: 20s
      max_output_tokens: 300
    includes:
      event_groups: []
      personas: []
      bindings: []
      triggers: []
      routing: []
    """

    assert {:ok, document} = DocumentDecoder.decode(yaml)

    assert {:ok,
            %Manifest{
              version: 1,
              llm: %LLM{timeout_ms: 20_000},
              state_tracking: %StateTracking{failures_required: 2, successes_required: 2},
              conversation_defaults: %ConversationDefaults{
                max_turns: 3,
                max_participants: 2,
                max_duration_ms: 300_000,
                max_llm_calls: 3,
                allow_same_persona_consecutively: false,
                allow_persona_reentry: true,
                no_reply_weight: 1.0,
                random_jitter: 0.2
              },
              event_policy: %EventPolicy{
                dedupe_window_ms: 300_000,
                retention_ms: 7_776_000_000
              }
            }} =
             Manifest.parse(document)
  end

  test "validates and normalizes the version 1 manifest" do
    document = %{
      "version" => 1,
      "llm" => valid_llm(),
      "includes" => %{
        "event_groups" => ["event-groups.yaml"],
        "personas" => ["personas/*.yaml"],
        "bindings" => ["bindings/*.yaml"],
        "triggers" => ["triggers/*.yaml"],
        "routing" => ["routing.yaml"]
      }
    }

    assert Manifest.parse(document) ==
             {:ok,
              %Manifest{
                version: 1,
                llm: %LLM{
                  provider: :openai_compatible,
                  base_url_env: "LLM_BASE_URL",
                  model_env: "LLM_MODEL",
                  api_key_file_env: "LLM_API_KEY_FILE",
                  timeout_ms: 20_000,
                  max_output_tokens: 300
                },
                state_tracking: %StateTracking{
                  failures_required: 2,
                  successes_required: 2
                },
                includes: %{
                  event_groups: ["event-groups.yaml"],
                  personas: ["personas/*.yaml"],
                  bindings: ["bindings/*.yaml"],
                  triggers: ["triggers/*.yaml"],
                  routing: ["routing.yaml"]
                }
              }}
  end

  test "normalizes optional explicit state-tracking settings" do
    document =
      valid_document()
      |> Map.put("state_tracking", %{
        "failures_required" => 3,
        "successes_required" => 4
      })

    assert {:ok,
            %Manifest{
              state_tracking: %StateTracking{
                failures_required: 3,
                successes_required: 4
              }
            }} = Manifest.parse(document)
  end

  test "normalizes optional explicit conversation defaults" do
    document =
      valid_document()
      |> Map.put("conversation_defaults", %{
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
      })

    assert {:ok,
            %Manifest{
              conversation_defaults: %ConversationDefaults{
                max_turns: 5,
                max_participants: 4,
                max_duration_ms: 90_000,
                max_llm_calls: 6,
                allow_same_persona_consecutively: true,
                allow_persona_reentry: false,
                no_reply_weight: 2.5,
                random_jitter: 0.4
              }
            }} = Manifest.parse(document)

    assert Manifest.parse(Map.put(valid_document(), "conversation_defaults", %{})) ==
             {:error, {:conversation_defaults, :invalid_conversation_defaults}}
  end

  test "normalizes optional explicit event policy" do
    document =
      valid_document()
      |> Map.put("event_policy", %{
        "dedupe_window" => "90s",
        "retention" => "30d"
      })

    assert {:ok,
            %Manifest{
              event_policy: %EventPolicy{
                dedupe_window_ms: 90_000,
                retention_ms: 2_592_000_000
              }
            }} = Manifest.parse(document)

    assert Manifest.parse(Map.put(valid_document(), "event_policy", %{})) ==
             {:error, {:event_policy, :invalid_event_policy}}
  end

  test "allows present categories to have no include patterns" do
    document = valid_document(%{"routing" => []})

    assert {:ok, %Manifest{includes: %{routing: []}}} = Manifest.parse(document)
  end

  test "requires every fixed field and rejects unknown top-level fields" do
    oversized =
      Map.merge(
        valid_document(),
        Map.new(1..10_000, fn index -> {"forged-#{index}", "value"} end)
      )

    for document <- [nil, [], "version: 1"] do
      assert Manifest.parse(document) == {:error, :invalid_manifest}
    end

    assert Manifest.parse(Map.delete(valid_document(), "version")) ==
             {:error, :missing_manifest_field}

    assert Manifest.parse(Map.delete(valid_document(), "llm")) ==
             {:error, :missing_manifest_field}

    assert Manifest.parse(Map.put(valid_document(), "extra", true)) ==
             {:error, :unknown_manifest_field}

    assert Manifest.parse(oversized) == {:error, :unknown_manifest_field}

    assert Manifest.parse(%{version: 1, includes: %{}}) ==
             {:error, :missing_manifest_field}
  end

  test "accepts only configuration version 1 as an integer" do
    assert Manifest.parse(valid_document(%{}, 2)) == {:error, :unsupported_config_version}
    assert Manifest.parse(valid_document(%{}, 0)) == {:error, :unsupported_config_version}

    for version <- ["1", 1.0, true, nil] do
      assert Manifest.parse(valid_document(%{}, version)) ==
               {:error, :invalid_config_version}
    end
  end

  test "requires an includes mapping with every version 1 category" do
    assert Manifest.parse(%{"version" => 1, "llm" => valid_llm(), "includes" => []}) ==
             {:error, :invalid_includes}

    includes = valid_includes()

    for category <- Map.keys(includes) do
      document = %{
        "version" => 1,
        "llm" => valid_llm(),
        "includes" => Map.delete(includes, category)
      }

      assert Manifest.parse(document) == {:error, :missing_include_category}
    end

    document = %{
      "version" => 1,
      "llm" => valid_llm(),
      "includes" => Map.put(includes, "prompts", ["prompts/*.md"])
    }

    assert Manifest.parse(document) == {:error, :unknown_include_category}
  end

  test "requires proper lists containing only string patterns" do
    invalid_patterns = ["personas/*.yaml", 1]

    assert Manifest.parse(valid_document(%{"personas" => invalid_patterns})) ==
             {:error, :invalid_include_patterns}

    assert Manifest.parse(valid_document(%{"bindings" => "bindings/*.yaml"})) ==
             {:error, :invalid_include_patterns}

    improper = ["routing.yaml" | "extra.yaml"]

    assert Manifest.parse(valid_document(%{"routing" => improper})) ==
             {:error, :invalid_include_patterns}
  end

  test "bounds include patterns across all categories" do
    sixty_four_patterns = Enum.map(1..64, &"personas/#{&1}.yaml")
    document = valid_document(%{"personas" => sixty_four_patterns})

    assert {:ok, %Manifest{includes: %{personas: ^sixty_four_patterns}}} =
             Manifest.parse(document)

    document =
      valid_document(%{
        "personas" => Enum.map(1..32, &"personas/#{&1}.yaml"),
        "bindings" => Enum.map(1..33, &"bindings/#{&1}.yaml")
      })

    assert Manifest.parse(document) == {:error, :too_many_include_patterns}
  end

  test "labels invalid LLM configuration without exposing rejected values" do
    document = put_in(valid_document(), ["llm", "provider"], "private-provider")
    result = Manifest.parse(document)

    assert result == {:error, {:llm, :invalid_llm_configuration}}
    refute inspect(result) =~ "private"
  end

  test "labels invalid state-tracking configuration without exposing rejected values" do
    document =
      valid_document()
      |> Map.put("state_tracking", %{
        "failures_required" => 2,
        "successes_required" => "private-value"
      })

    result = Manifest.parse(document)

    assert result ==
             {:error, {:state_tracking, :invalid_state_tracking_configuration}}

    refute inspect(result) =~ "private"
  end

  defp valid_document(overrides \\ %{}, version \\ 1) do
    %{
      "version" => version,
      "llm" => valid_llm(),
      "includes" => Map.merge(valid_includes(), overrides)
    }
  end

  defp valid_includes do
    %{
      "event_groups" => [],
      "personas" => [],
      "bindings" => [],
      "triggers" => [],
      "routing" => []
    }
  end

  defp valid_llm do
    %{
      "provider" => "openai_compatible",
      "base_url_env" => "LLM_BASE_URL",
      "model_env" => "LLM_MODEL",
      "api_key_file_env" => "LLM_API_KEY_FILE",
      "timeout" => "20s",
      "max_output_tokens" => 300
    }
  end
end

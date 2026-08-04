defmodule ClusterMurmur.Config.ManifestTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{DocumentDecoder, Manifest}

  test "accepts the bounded decoder output" do
    yaml = """
    version: 1
    includes:
      event_groups: []
      personas: []
      bindings: []
      triggers: []
      routing: []
    """

    assert {:ok, document} = DocumentDecoder.decode(yaml)
    assert {:ok, %Manifest{version: 1}} = Manifest.parse(document)
  end

  test "validates and normalizes the version 1 manifest" do
    document = %{
      "version" => 1,
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
                includes: %{
                  event_groups: ["event-groups.yaml"],
                  personas: ["personas/*.yaml"],
                  bindings: ["bindings/*.yaml"],
                  triggers: ["triggers/*.yaml"],
                  routing: ["routing.yaml"]
                }
              }}
  end

  test "allows present categories to have no include patterns" do
    document = valid_document(%{"routing" => []})

    assert {:ok, %Manifest{includes: %{routing: []}}} = Manifest.parse(document)
  end

  test "requires a mapping with exactly the versioned top-level fields" do
    for document <- [nil, [], "version: 1"] do
      assert Manifest.parse(document) == {:error, :invalid_manifest}
    end

    assert Manifest.parse(Map.delete(valid_document(), "version")) ==
             {:error, :missing_manifest_field}

    assert Manifest.parse(Map.put(valid_document(), "extra", true)) ==
             {:error, :unknown_manifest_field}

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
    assert Manifest.parse(%{"version" => 1, "includes" => []}) ==
             {:error, :invalid_includes}

    includes = valid_includes()

    for category <- Map.keys(includes) do
      document = %{"version" => 1, "includes" => Map.delete(includes, category)}
      assert Manifest.parse(document) == {:error, :missing_include_category}
    end

    document = %{"version" => 1, "includes" => Map.put(includes, "prompts", ["prompts/*.md"])}
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

  defp valid_document(overrides \\ %{}, version \\ 1) do
    %{"version" => version, "includes" => Map.merge(valid_includes(), overrides)}
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
end

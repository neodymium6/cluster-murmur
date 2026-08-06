defmodule ClusterMurmur.Config.PersonasTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{LoadedDocument, Personas}
  alias ClusterMurmur.Personas.Persona
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    root = PrivateTmpDir.create!("cluster-murmur-personas")

    config = write(root, "cluster-murmur.yaml", "version: 1\n")
    first = write(root, "personas/first.yaml", "personas: []\n")
    second = write(root, "personas/second.yaml", "personas: []\n")
    write(root, "prompts/observer.md", "Observe only supplied facts.\n")
    write(root, "prompts/caretaker.md", "Respond carefully.\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, config: config, first: first, second: second}
  end

  test "validates, normalizes, and combines personas with bounded prompts", context do
    first =
      document(context.first, %{
        "personas" => [
          %{
            "id" => "observer",
            "display_name" => "Observer",
            "avatar" => "https://example.com/observer.png",
            "prompt_file" => "../prompts/observer.md",
            "enabled" => false,
            "interests" => %{"operations" => 1.0},
            "behavior" => %{
              "spontaneous_weight" => 0.3,
              "reply_weight" => 0.8,
              "cooldown" => "30m"
            },
            "relationships" => %{},
            "metadata" => %{}
          }
        ]
      })

    second =
      document(context.second, %{
        "personas" => [
          %{
            "id" => "caretaker",
            "display_name" => "Caretaker",
            "prompt_file" => "../prompts/caretaker.md"
          }
        ]
      })

    assert {:ok, %Personas{personas: personas}} =
             Personas.parse_documents(context.config, [first, second])

    assert %Persona{enabled: false, interests: %{"operations" => 1.0}, behavior: behavior} =
             personas["observer"]

    assert behavior == %{
             "cooldown_ms" => 1_800_000,
             "reply_weight" => 0.8,
             "spontaneous_weight" => 0.3
           }

    assert %Persona{enabled: true, avatar: nil, interests: %{}, behavior: %{}} =
             personas["caretaker"]
  end

  test "accepts empty persona categories", context do
    assert Personas.parse_documents(context.config, []) == {:ok, %Personas{personas: %{}}}

    assert Personas.parse_documents(context.config, [document(context.first, %{"personas" => []})]) ==
             {:ok, %Personas{personas: %{}}}
  end

  test "rejects closed-schema violations", context do
    valid = %{
      "id" => "observer",
      "display_name" => "Observer",
      "prompt_file" => "../prompts/observer.md"
    }

    invalid = [
      %{},
      %{"personas" => %{}},
      %{"personas" => [Map.put(valid, "extra", true)]},
      %{"personas" => [Map.delete(valid, "prompt_file")]},
      %{"personas" => [Map.put(valid, "enabled", 1)]},
      %{"personas" => [Map.put(valid, "relationships", %{"other" => true})]},
      %{"personas" => [Map.put(valid, "metadata", %{"private" => true})]}
    ]

    for value <- invalid do
      assert Personas.parse_documents(context.config, [document(context.first, value)]) ==
               {:error, :invalid_persona_document}
    end
  end

  test "applies semantic display-name and avatar bounds", context do
    base = %{
      "id" => "observer",
      "display_name" => "Observer",
      "prompt_file" => "../prompts/observer.md"
    }

    for attributes <- [
          Map.put(base, "display_name", "   "),
          Map.put(base, "display_name", String.duplicate("a", 129)),
          Map.put(base, "display_name", <<255>>),
          Map.put(base, "avatar", "http://example.com/avatar.png"),
          Map.put(base, "avatar", "https://user@example.com/avatar.png"),
          Map.put(base, "avatar", "https://"),
          Map.put(base, "avatar", "https://example.com/%ZZ"),
          Map.put(base, "avatar", "https://example.com/%"),
          Map.put(base, "avatar", "https://example.com/%A"),
          Map.put(base, "avatar", "https://example.com/%0"),
          Map.put(base, "avatar", <<"https://example.com/", 255>>)
        ] do
      assert Personas.parse_documents(context.config, [
               document(context.first, %{"personas" => [attributes]})
             ]) ==
               {:error, :invalid_persona_document}
    end
  end

  test "rejects invalid interests and behavior", context do
    base = %{
      "id" => "observer",
      "display_name" => "Observer",
      "prompt_file" => "../prompts/observer.md"
    }

    for extra <- [
          %{"interests" => %{"invalid id" => 1}},
          %{"interests" => %{"operations" => -1}},
          %{"behavior" => %{"reply_weight" => -1}},
          %{"behavior" => %{"cooldown" => "later"}},
          %{"behavior" => %{"cooldown" => "366d"}},
          %{"behavior" => %{"unknown" => true}}
        ] do
      attributes = Map.merge(base, extra)

      assert Personas.parse_documents(context.config, [
               document(context.first, %{"personas" => [attributes]})
             ]) ==
               {:error, :invalid_persona_document}
    end
  end

  test "rejects duplicate IDs and more than 256 personas", context do
    persona = fn id ->
      %{"id" => id, "display_name" => id, "prompt_file" => "../prompts/observer.md"}
    end

    first = document(context.first, %{"personas" => [persona.("observer")]})
    second = document(context.second, %{"personas" => [persona.("observer")]})

    assert Personas.parse_documents(context.config, [first, second]) ==
             {:error, :duplicate_persona}

    allowed = Enum.map(1..256, &persona.("persona-#{&1}"))

    assert {:ok, %Personas{personas: personas}} =
             Personas.parse_documents(context.config, [
               document(context.first, %{"personas" => allowed})
             ])

    assert map_size(personas) == 256

    overflow = document(context.second, %{"personas" => [persona.("persona-257")]})

    assert Personas.parse_documents(context.config, [
             document(context.first, %{"personas" => allowed}),
             overflow
           ]) ==
             {:error, :too_many_personas}
  end

  test "returns categorized prompt failures", context do
    attributes = %{
      "id" => "observer",
      "display_name" => "Observer",
      "prompt_file" => "../prompts/missing.md"
    }

    assert Personas.parse_documents(context.config, [
             document(context.first, %{"personas" => [attributes]})
           ]) ==
             {:error, {:prompt, :prompt_target_invalid}}

    assert Personas.parse_documents("missing.yaml", []) ==
             {:error, {:prompt, :invalid_config_path}}
  end

  test "rejects malformed document collections", context do
    assert Personas.parse_documents(context.config, nil) == {:error, :invalid_persona_document}
    assert Personas.parse_documents(nil, []) == {:error, {:prompt, :invalid_config_path}}
    assert Personas.parse_documents(context.config, [%{}]) == {:error, :invalid_persona_document}

    for document <- [
          URI.parse("https://example.com"),
          %{"personas" => [%{"behavior" => URI.parse("https://example.com")}]},
          %{"personas" => [%{} | :tail]}
        ] do
      assert Personas.parse_documents(context.config, [
               %LoadedDocument{path: context.first, document: document}
             ]) == {:error, :invalid_persona_document}
    end
  end

  test "redacts prompt and persona values from inspection" do
    persona = %Persona{id: "private-persona", display_name: "Private", prompt: "private prompt"}
    set = %Personas{personas: %{"private-persona" => persona}}

    for inspected <- [inspect(persona), inspect(set)] do
      refute inspected =~ "private-persona"
      refute inspected =~ "private prompt"
    end
  end

  defp document(path, value), do: %LoadedDocument{path: path, document: value}

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Path.expand(path)
  end
end

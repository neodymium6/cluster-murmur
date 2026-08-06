defmodule ClusterMurmur.Config.CatalogTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Catalog, DocumentSet, LLM, LoadedDocument, Manifest}
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    root = PrivateTmpDir.create!("cluster-murmur-catalog")

    config = write(root, "cluster-murmur.yaml", "version: 1\n")
    persona_source = write(root, "personas/observer.yaml", "personas: []\n")
    write(root, "prompts/observer.md", "Use only supplied facts.\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, config: config, persona_source: persona_source}
  end

  test "assembles parsed categories and resolves binding references", context do
    set = document_set(context, "operations", "observer")

    assert {:ok, %Catalog{} = catalog} = Catalog.parse(context.config, set)
    assert Map.has_key?(catalog.event_groups.groups, "operations")
    assert Map.has_key?(catalog.personas.personas, "observer")
    assert Map.has_key?(catalog.bindings.bindings, "monitoring")
  end

  test "rejects unknown binding groups after all categories parse", context do
    set = document_set(context, "missing", "observer")
    assert Catalog.parse(context.config, set) == {:error, :unknown_binding_group}
  end

  test "rejects unknown binding personas while allowing disabled references", context do
    set = document_set(context, "operations", "missing")
    assert Catalog.parse(context.config, set) == {:error, :unknown_binding_persona}

    set = document_set(context, "operations", "observer", false)
    assert {:ok, %Catalog{}} = Catalog.parse(context.config, set)
  end

  test "labels category failures without exposing values", context do
    documents = valid_documents(context)

    invalid =
      put_in(documents, [:bindings], [
        loaded("/config/private.yaml", %{"bindings" => [%{"private" => true}]})
      ])

    set = %DocumentSet{manifest: manifest(), documents: invalid}
    result = Catalog.parse(context.config, set)

    assert result == {:error, {:bindings, :invalid_binding_document}}
    refute inspect(result) =~ "private"
  end

  test "rejects malformed or unsupported document sets", context do
    assert Catalog.parse(context.config, nil) == {:error, :invalid_catalog}

    for forged <- [
          %{__struct__: DocumentSet},
          %{__struct__: DocumentSet, manifest: manifest()},
          %{__struct__: DocumentSet, documents: valid_documents(context)}
        ] do
      assert Catalog.parse(context.config, forged) == {:error, :invalid_catalog}
    end

    assert Catalog.parse(context.config, %DocumentSet{manifest: manifest(), documents: %{}}) ==
             {:error, :invalid_catalog}

    incomplete = %DocumentSet{
      manifest: %Manifest{version: 1, includes: nil, llm: llm()},
      documents: %{event_groups: [], personas: [], bindings: []}
    }

    assert Catalog.parse(context.config, incomplete) == {:error, :invalid_catalog}

    malformed_documents = put_in(valid_documents(context), [:routing], [%{}])

    assert Catalog.parse(
             context.config,
             %DocumentSet{manifest: manifest(), documents: malformed_documents}
           ) == {:error, :invalid_catalog}

    unsupported = %DocumentSet{
      manifest: %Manifest{version: 2, includes: includes(), llm: llm()},
      documents: valid_documents(context)
    }

    assert Catalog.parse(context.config, unsupported) == {:error, :invalid_catalog}
  end

  test "redacts assembled values from inspection", context do
    assert {:ok, catalog} =
             Catalog.parse(context.config, document_set(context, "operations", "observer"))

    inspected = inspect(catalog)
    assert inspected =~ "version: 1"
    refute inspected =~ "operations"
    refute inspected =~ "observer"
  end

  defp document_set(context, group, persona, enabled \\ true) do
    documents = valid_documents(context, group, persona, enabled)
    %DocumentSet{manifest: manifest(), documents: documents}
  end

  defp valid_documents(
         context,
         binding_group \\ "operations",
         candidate \\ "observer",
         enabled \\ true
       ) do
    %{
      event_groups: [
        loaded("/config/event-groups.yaml", %{
          "event_groups" => %{"operations" => %{"reply_probability" => 0.25}}
        })
      ],
      personas: [
        loaded(context.persona_source, %{
          "personas" => [
            %{
              "id" => "observer",
              "display_name" => "Observer",
              "prompt_file" => "../prompts/observer.md",
              "enabled" => enabled
            }
          ]
        })
      ],
      bindings: [
        loaded("/config/bindings.yaml", %{
          "bindings" => [
            %{
              "id" => "monitoring",
              "match" => %{"group" => binding_group},
              "candidates" => [%{"persona" => candidate, "weight" => 1}]
            }
          ]
        })
      ],
      triggers: [],
      routing: []
    }
  end

  defp manifest, do: %Manifest{version: 1, includes: includes(), llm: llm()}
  defp includes, do: %{event_groups: [], personas: [], bindings: [], triggers: [], routing: []}

  defp llm,
    do: %LLM{
      provider: :openai_compatible,
      base_url_env: "LLM_BASE_URL",
      model_env: "LLM_MODEL",
      api_key_file_env: "LLM_API_KEY_FILE",
      timeout_ms: 20_000,
      max_output_tokens: 300
    }

  defp loaded(path, document), do: %LoadedDocument{path: path, document: document}

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Path.expand(path)
  end
end

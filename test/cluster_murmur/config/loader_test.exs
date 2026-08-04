defmodule ClusterMurmur.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{DocumentSet, LoadedDocument, LoadPlan, Loader, Manifest}

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-loader-test-#{System.unique_integer([:positive])}"
      )

    config_root = Path.join(test_root, "config")
    config_file = Path.join(config_root, "cluster-murmur.yaml")
    File.mkdir_p!(config_root)

    on_exit(fn -> File.rm_rf!(test_root) end)

    %{config_file: config_file, config_root: config_root}
  end

  test "builds a deterministic categorized plan from a valid manifest", context do
    observer = write_fixture(context.config_root, "personas/observer.yaml", "not: validated: yet")
    caretaker = write_fixture(context.config_root, "personas/caretaker.yaml")
    shared = write_fixture(context.config_root, "shared.yaml")

    write_manifest(context.config_file, """
    version: 1
    includes:
      event_groups: []
      personas:
        - personas/*.yaml
        - shared.yaml
      bindings:
        - shared.yaml
      triggers: []
      routing: []
    """)

    assert Loader.load_manifest(context.config_file) ==
             {:ok,
              %LoadPlan{
                manifest: %Manifest{
                  version: 1,
                  includes: %{
                    event_groups: [],
                    personas: ["personas/*.yaml", "shared.yaml"],
                    bindings: ["shared.yaml"],
                    triggers: [],
                    routing: []
                  }
                },
                files: %{
                  event_groups: [],
                  personas: Enum.sort([observer, caretaker, shared]),
                  bindings: [shared],
                  triggers: [],
                  routing: []
                }
              }}
  end

  test "labels bounded document decoding errors", context do
    write_manifest(context.config_file, "[unterminated")

    assert Loader.load_manifest(context.config_file) == {:error, {:document, :invalid_yaml}}
    assert Loader.load_manifest(nil) == {:error, {:document, :invalid_document_path}}
  end

  test "labels manifest validation errors before resolving includes", context do
    write_manifest(context.config_file, """
    version: 2
    includes: {}
    """)

    assert Loader.load_manifest(context.config_file) ==
             {:error, {:manifest, :unsupported_config_version}}
  end

  test "labels include resolution errors", context do
    write_manifest(context.config_file, """
    version: 1
    includes:
      event_groups: []
      personas:
        - personas/*.yaml
      bindings: []
      triggers: []
      routing: []
    """)

    assert Loader.load_manifest(context.config_file) ==
             {:error, {:includes, :include_not_found}}
  end

  test "decodes categorized included documents while retaining their sources", context do
    persona = write_fixture(context.config_root, "personas/observer.yaml", "personas: []\n")
    shared = write_fixture(context.config_root, "shared.yaml", "entries:\n  - shared\n")

    write_manifest(context.config_file, """
    version: 1
    includes:
      event_groups: []
      personas:
        - personas/*.yaml
        - shared.yaml
      bindings:
        - shared.yaml
      triggers: []
      routing: []
    """)

    assert {:ok,
            %DocumentSet{
              manifest: %Manifest{version: 1},
              documents: %{
                event_groups: [],
                personas: persona_documents,
                bindings: [shared_document],
                triggers: [],
                routing: []
              }
            }} = Loader.load_documents(context.config_file)

    assert persona_documents == [
             %LoadedDocument{path: persona, document: %{"personas" => []}},
             %LoadedDocument{path: shared, document: %{"entries" => ["shared"]}}
           ]

    assert shared_document ==
             %LoadedDocument{path: shared, document: %{"entries" => ["shared"]}}
  end

  test "labels included document decoding errors without exposing their source", context do
    private_path = write_fixture(context.config_root, "personas/private-node.yaml", "[broken")

    write_manifest(context.config_file, """
    version: 1
    includes:
      event_groups: []
      personas:
        - personas/*.yaml
      bindings: []
      triggers: []
      routing: []
    """)

    result = Loader.load_documents(context.config_file)

    assert result == {:error, {:included_document, :invalid_yaml}}
    refute inspect(result) =~ private_path
  end

  test "configuration loading structs redact paths, patterns, and decoded values from inspection",
       context do
    private_path = Path.join(context.config_root, "private-node.yaml")

    manifest = %Manifest{version: 1, includes: valid_includes("private-node.yaml")}
    plan = %LoadPlan{manifest: manifest, files: Map.put(valid_files(), :personas, [private_path])}

    loaded = %LoadedDocument{path: private_path, document: %{"private" => "value"}}

    set = %DocumentSet{
      manifest: manifest,
      documents: Map.put(valid_documents(), :personas, [loaded])
    }

    for inspected <- Enum.map([manifest, plan, loaded, set], &inspect/1) do
      refute inspected =~ "private-node.yaml"
      refute inspected =~ "private"
      refute inspected =~ "value"
    end

    assert inspect(manifest) =~ "version: 1"
  end

  defp write_manifest(path, contents), do: File.write!(path, contents)

  defp write_fixture(root, relative_path, contents \\ "version: 1\n") do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Path.expand(path)
  end

  defp valid_includes(persona_pattern) do
    %{
      event_groups: [],
      personas: [persona_pattern],
      bindings: [],
      triggers: [],
      routing: []
    }
  end

  defp valid_files do
    %{event_groups: [], personas: [], bindings: [], triggers: [], routing: []}
  end

  defp valid_documents do
    %{event_groups: [], personas: [], bindings: [], triggers: [], routing: []}
  end
end

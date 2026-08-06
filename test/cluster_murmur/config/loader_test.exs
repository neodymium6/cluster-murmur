defmodule ClusterMurmur.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Catalog, Configuration, DocumentSet, LLM, LoadedDocument}
  alias ClusterMurmur.Config.{LoadPlan, Loader, Manifest, StateTracking}
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    test_root = PrivateTmpDir.create!("cluster-murmur-loader-test")

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
    llm:
      provider: openai_compatible
      base_url_env: LLM_BASE_URL
      model_env: LLM_MODEL
      api_key_file_env: LLM_API_KEY_FILE
      timeout: 20s
      max_output_tokens: 300
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
                  llm: llm(),
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
    llm:
      provider: openai_compatible
      base_url_env: LLM_BASE_URL
      model_env: LLM_MODEL
      api_key_file_env: LLM_API_KEY_FILE
      timeout: 20s
      max_output_tokens: 300
    includes: {}
    """)

    assert Loader.load_manifest(context.config_file) ==
             {:error, {:manifest, :unsupported_config_version}}
  end

  test "labels include resolution errors", context do
    write_manifest(context.config_file, """
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
    llm:
      provider: openai_compatible
      base_url_env: LLM_BASE_URL
      model_env: LLM_MODEL
      api_key_file_env: LLM_API_KEY_FILE
      timeout: 20s
      max_output_tokens: 300
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
    llm:
      provider: openai_compatible
      base_url_env: LLM_BASE_URL
      model_env: LLM_MODEL
      api_key_file_env: LLM_API_KEY_FILE
      timeout: 20s
      max_output_tokens: 300
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

  test "loads the implemented catalog and labels reference failures", context do
    write_fixture(context.config_root, "event-groups.yaml", """
    event_groups:
      operations:
        reply_probability: 0.25
    """)

    write_fixture(context.config_root, "prompts/observer.md", "Use supplied facts only.\n")

    write_fixture(context.config_root, "personas/observer.yaml", """
    personas:
      - id: observer
        display_name: Observer
        prompt_file: ../prompts/observer.md
    """)

    binding_path =
      write_fixture(context.config_root, "bindings/monitoring.yaml", """
      bindings:
        - id: monitoring
          match:
            group: operations
          candidates:
            - persona: observer
              weight: 1
      """)

    write_manifest(context.config_file, catalog_manifest())
    assert {:ok, %Catalog{version: 1}} = Loader.load_catalog(context.config_file)

    File.write!(binding_path, String.replace(File.read!(binding_path), "operations", "missing"))

    assert Loader.load_catalog(context.config_file) ==
             {:error, {:catalog, :unknown_binding_group}}
  end

  test "loads the complete configuration and labels assembly failures", context do
    write_fixture(context.config_root, "event-groups.yaml", """
    event_groups:
      operations:
        reply_probability: 0.25
    """)

    write_fixture(context.config_root, "prompts/observer.md", "Use supplied facts only.\n")

    write_fixture(context.config_root, "personas/observer.yaml", """
    personas:
      - id: observer
        display_name: Observer
        prompt_file: ../prompts/observer.md
    """)

    write_fixture(context.config_root, "bindings/monitoring.yaml", """
    bindings:
      - id: monitoring
        match:
          group: operations
        candidates:
          - persona: observer
            weight: 1
    """)

    trigger_path =
      write_fixture(context.config_root, "triggers/monitoring.yaml", """
      triggers:
        - id: monitoring-failure
          event:
            match:
              all:
                - field: type
                  operator: equals
                  value: observation.failed
          action:
            type: start_conversation
            binding: monitoring
          cooldown: 30m
      """)

    write_fixture(context.config_root, "triggers/schedules.yaml", """
    triggers:
      - id: daily-summary
        schedule:
          cron: "0 21 * * *"
          timezone: Asia/Tokyo
        action:
          type: emit_event
          event:
            type: schedule.fired
            group: operations
            subject: daily-summary
    """)

    write_fixture(context.config_root, "triggers/stochastic.yaml", """
    triggers:
      - id: ambient
        stochastic:
          distribution: shifted_exponential
          mean_interval: 8h
          minimum_interval: 2h
          active_hours:
            start: "23:00"
            end: "08:00"
            timezone: Asia/Tokyo
          daily_limit: 3
        action:
          type: emit_event
          event:
            type: stochastic.fired
            group: operations
            subject: ambient
    """)

    write_fixture(context.config_root, "routing.yaml", """
    routing:
      default:
        webhook_secret_file_env: DISCORD_WEBHOOK_SECRET_FILE
    """)

    write_manifest(context.config_file, configuration_manifest())

    assert {:ok, %Configuration{version: 1} = configuration} =
             Loader.load_configuration(context.config_file)

    assert configuration.llm == llm()

    assert configuration.state_tracking ==
             %StateTracking{failures_required: 3, successes_required: 4}

    assert %{action: :emit_event, timezone: "Asia/Tokyo"} =
             configuration.triggers.triggers["daily-summary"]

    assert %{distribution: :shifted_exponential, daily_limit: 3} =
             configuration.triggers.triggers["ambient"]

    File.write!(
      trigger_path,
      String.replace(File.read!(trigger_path), "monitoring\n", "missing\n")
    )

    assert Loader.load_configuration(context.config_file) ==
             {:error, {:configuration, :unknown_trigger_binding}}
  end

  test "configuration loading structs redact paths, patterns, and decoded values from inspection",
       context do
    private_path = Path.join(context.config_root, "private-node.yaml")

    manifest = %Manifest{
      version: 1,
      includes: valid_includes("private-node.yaml"),
      llm: llm()
    }

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

  defp llm do
    %LLM{
      provider: :openai_compatible,
      base_url_env: "LLM_BASE_URL",
      model_env: "LLM_MODEL",
      api_key_file_env: "LLM_API_KEY_FILE",
      timeout_ms: 20_000,
      max_output_tokens: 300
    }
  end

  defp catalog_manifest do
    """
    version: 1
    state_tracking:
      failures_required: 3
      successes_required: 4
    llm:
      provider: openai_compatible
      base_url_env: LLM_BASE_URL
      model_env: LLM_MODEL
      api_key_file_env: LLM_API_KEY_FILE
      timeout: 20s
      max_output_tokens: 300
    includes:
      event_groups:
        - event-groups.yaml
      personas:
        - personas/*.yaml
      bindings:
        - bindings/*.yaml
      triggers: []
      routing: []
    """
  end

  defp configuration_manifest do
    """
    version: 1
    state_tracking:
      failures_required: 3
      successes_required: 4
    llm:
      provider: openai_compatible
      base_url_env: LLM_BASE_URL
      model_env: LLM_MODEL
      api_key_file_env: LLM_API_KEY_FILE
      timeout: 20s
      max_output_tokens: 300
    includes:
      event_groups:
        - event-groups.yaml
      personas:
        - personas/*.yaml
      bindings:
        - bindings/*.yaml
      triggers:
        - triggers/*.yaml
      routing:
        - routing.yaml
    """
  end
end

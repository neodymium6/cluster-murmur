defmodule ClusterMurmur.Config.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{
    Configuration,
    ConversationDefaults,
    DocumentSet,
    EventPolicy,
    LLM,
    LoadedDocument,
    Manifest
  }

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    root = PrivateTmpDir.create!("cluster-murmur-configuration")

    config = write(root, "cluster-murmur.yaml", "version: 1\n")
    persona_source = write(root, "personas/observer.yaml", "personas: []\n")
    write(root, "prompts/observer.md", "Use only supplied facts.\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{config: config, persona_source: persona_source}
  end

  test "assembles every implemented category and resolves trigger bindings", context do
    assert {:ok, %Configuration{} = configuration} =
             Configuration.parse(context.config, document_set(context))

    assert configuration.version == 1
    assert Map.has_key?(configuration.event_groups.groups, "operations")
    assert Map.has_key?(configuration.personas.personas, "observer")
    assert Map.has_key?(configuration.bindings.bindings, "monitoring")
    assert Map.has_key?(configuration.triggers.triggers, "monitoring-failure")
    assert configuration.routing.webhook_secret_file_env == "DISCORD_WEBHOOK_SECRET_FILE"
    assert configuration.llm == llm()
    assert configuration.state_tracking == StateTracking.default()
    assert configuration.conversation_defaults == ConversationDefaults.default()
    assert configuration.event_policy == EventPolicy.default()
    assert Configuration.validate(configuration) == :ok
  end

  test "carries explicit state-tracking settings into complete configuration", context do
    state_tracking = %StateTracking{failures_required: 3, successes_required: 4}
    manifest = %{manifest() | state_tracking: state_tracking}

    assert {:ok, %Configuration{state_tracking: ^state_tracking}} =
             Configuration.parse(
               context.config,
               %DocumentSet{manifest: manifest, documents: valid_documents(context)}
             )
  end

  test "carries explicit conversation defaults into complete configuration", context do
    defaults = %{ConversationDefaults.default() | max_turns: 5, no_reply_weight: 2.5}
    manifest = %{manifest() | conversation_defaults: defaults}

    assert {:ok, %Configuration{conversation_defaults: ^defaults}} =
             Configuration.parse(
               context.config,
               %DocumentSet{manifest: manifest, documents: valid_documents(context)}
             )
  end

  test "carries explicit event policy into complete configuration", context do
    policy = %EventPolicy{dedupe_window_ms: 90_000, retention_ms: 2_592_000_000}
    manifest = %{manifest() | event_policy: policy}

    assert {:ok, %Configuration{event_policy: ^policy}} =
             Configuration.parse(
               context.config,
               %DocumentSet{manifest: manifest, documents: valid_documents(context)}
             )
  end

  test "revalidates exact category values and catalog references", context do
    assert {:ok, configuration} = Configuration.parse(context.config, document_set(context))

    for field <- [
          :event_groups,
          :personas,
          :bindings,
          :triggers,
          :routing,
          :llm,
          :state_tracking,
          :conversation_defaults,
          :event_policy
        ] do
      assert configuration
             |> Map.put(field, nil)
             |> Configuration.validate() == {:error, :invalid_configuration}
    end

    for invalid <- [
          %{configuration | version: 1.0},
          Map.put(configuration, :private, true),
          put_in(
            configuration.event_groups.groups["operations"].reply_probability,
            2
          ),
          put_in(configuration.personas.personas["observer"].display_name, ""),
          put_in(configuration.bindings.bindings["monitoring"].candidates, []),
          put_in(configuration.triggers.triggers["monitoring-failure"].cooldown_ms, -1),
          %{
            configuration
            | routing: %{configuration.routing | webhook_secret_file_env: "bad-name"}
          },
          %{configuration | llm: %{configuration.llm | timeout_ms: 0}},
          %{
            configuration
            | state_tracking: %{configuration.state_tracking | failures_required: 0}
          },
          %{
            configuration
            | conversation_defaults: %{
                configuration.conversation_defaults
                | no_reply_weight: 0
              }
          },
          %{
            configuration
            | event_policy: %{configuration.event_policy | retention_ms: 1}
          }
        ] do
      assert Configuration.validate(invalid) == {:error, :invalid_configuration}
    end

    unknown_group = put_in(configuration.bindings.bindings["monitoring"].group, "missing")

    assert Configuration.validate(unknown_group) ==
             {:error, {:catalog, :unknown_binding_group}}

    unknown_persona =
      put_in(configuration.bindings.bindings["monitoring"].candidates, [
        %{persona: "missing", weight: 1}
      ])

    assert Configuration.validate(unknown_persona) ==
             {:error, {:catalog, :unknown_binding_persona}}

    unknown_trigger_binding =
      put_in(configuration.triggers.triggers["monitoring-failure"].binding, "missing")

    assert Configuration.validate(unknown_trigger_binding) ==
             {:error, :unknown_trigger_binding}
  end

  test "rejects event triggers that reference unknown bindings", context do
    documents = put_in(valid_documents(context), [:triggers], trigger_documents("missing"))
    set = %DocumentSet{manifest: manifest(), documents: documents}

    assert Configuration.parse(context.config, set) == {:error, :unknown_trigger_binding}
  end

  test "assembles schedule triggers and resolves emitted event groups", context do
    documents =
      put_in(valid_documents(context), [:triggers], [
        loaded("/config/schedules.yaml", %{
          "triggers" => [schedule_trigger("daily-summary", "operations")]
        })
      ])

    assert {:ok, %Configuration{} = configuration} =
             Configuration.parse(
               context.config,
               %DocumentSet{manifest: manifest(), documents: documents}
             )

    assert %{action: :emit_event, event: %{group: "operations"}} =
             configuration.triggers.triggers["daily-summary"]

    assert Configuration.validate(configuration) == :ok

    invalid_timezone =
      put_in(configuration.triggers.triggers["daily-summary"].timezone, "Missing/Zone")

    assert Configuration.validate(invalid_timezone) == {:error, :invalid_configuration}

    forged_cron =
      Map.put(configuration.triggers.triggers["daily-summary"].cron, :private, :payload)

    forged_configuration =
      put_in(configuration.triggers.triggers["daily-summary"].cron, forged_cron)

    assert Configuration.validate(forged_configuration) == {:error, :invalid_configuration}
  end

  test "rejects schedule triggers that emit into unknown groups", context do
    documents =
      put_in(valid_documents(context), [:triggers], [
        loaded("/config/schedules.yaml", %{
          "triggers" => [schedule_trigger("daily-summary", "missing")]
        })
      ])

    set = %DocumentSet{manifest: manifest(), documents: documents}
    assert Configuration.parse(context.config, set) == {:error, :unknown_trigger_group}
  end

  test "assembles stochastic triggers and resolves emitted event groups", context do
    documents =
      put_in(valid_documents(context), [:triggers], [
        loaded("/config/stochastic.yaml", %{
          "triggers" => [stochastic_trigger("ambient", "operations")]
        })
      ])

    assert {:ok, %Configuration{} = configuration} =
             Configuration.parse(
               context.config,
               %DocumentSet{manifest: manifest(), documents: documents}
             )

    assert %{distribution: :shifted_exponential, event: %{group: "operations"}} =
             configuration.triggers.triggers["ambient"]

    assert Configuration.validate(configuration) == :ok

    equal_intervals =
      put_in(
        configuration.triggers.triggers["ambient"].mean_interval_ms,
        configuration.triggers.triggers["ambient"].minimum_interval_ms
      )

    assert Configuration.validate(equal_intervals) == {:error, :invalid_configuration}
  end

  test "rejects stochastic triggers that emit into unknown groups", context do
    documents =
      put_in(valid_documents(context), [:triggers], [
        loaded("/config/stochastic.yaml", %{
          "triggers" => [stochastic_trigger("ambient", "missing")]
        })
      ])

    set = %DocumentSet{manifest: manifest(), documents: documents}
    assert Configuration.parse(context.config, set) == {:error, :unknown_trigger_group}
  end

  test "labels category failures without exposing rejected values", context do
    invalid_triggers =
      put_in(valid_documents(context), [:triggers], [
        loaded("/config/private-trigger.yaml", %{"triggers" => [%{"private" => true}]})
      ])

    trigger_result =
      Configuration.parse(
        context.config,
        %DocumentSet{manifest: manifest(), documents: invalid_triggers}
      )

    assert trigger_result == {:error, {:triggers, :invalid_trigger_document}}
    refute inspect(trigger_result) =~ "private"

    no_routing = Map.put(valid_documents(context), :routing, [])

    assert Configuration.parse(
             context.config,
             %DocumentSet{manifest: manifest(), documents: no_routing}
           ) == {:error, {:routing, :missing_default_route}}
  end

  test "preserves catalog reference validation before complete assembly", context do
    documents = valid_documents(context, "missing")
    set = %DocumentSet{manifest: manifest(), documents: documents}

    assert Configuration.parse(context.config, set) ==
             {:error, {:catalog, :unknown_binding_group}}
  end

  test "rejects malformed document sets", context do
    assert Configuration.parse(context.config, nil) == {:error, :invalid_configuration}

    forged = %{__struct__: DocumentSet, manifest: manifest(), documents: %{}}

    assert Configuration.parse(context.config, forged) ==
             {:error, {:catalog, :invalid_catalog}}
  end

  test "redacts the complete configuration from inspection", context do
    assert {:ok, configuration} = Configuration.parse(context.config, document_set(context))

    inspected = inspect(configuration)
    assert inspected =~ "version: 1"

    for hidden <- ["operations", "observer", "monitoring", "DISCORD"] do
      refute inspected =~ hidden
    end
  end

  defp document_set(context) do
    %DocumentSet{manifest: manifest(), documents: valid_documents(context)}
  end

  defp valid_documents(context, binding_group \\ "operations") do
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
              "prompt_file" => "../prompts/observer.md"
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
              "candidates" => [%{"persona" => "observer", "weight" => 1}]
            }
          ]
        })
      ],
      triggers: trigger_documents("monitoring"),
      routing: [
        loaded("/config/routing.yaml", %{
          "routing" => %{
            "default" => %{"webhook_secret_file_env" => "DISCORD_WEBHOOK_SECRET_FILE"}
          }
        })
      ]
    }
  end

  defp trigger_documents(binding) do
    [
      loaded("/config/triggers.yaml", %{
        "triggers" => [
          %{
            "id" => "monitoring-failure",
            "event" => %{
              "match" => %{
                "all" => [
                  %{
                    "field" => "type",
                    "operator" => "equals",
                    "value" => "observation.failed"
                  }
                ]
              }
            },
            "action" => %{"type" => "start_conversation", "binding" => binding},
            "cooldown" => "30m"
          }
        ]
      })
    ]
  end

  defp schedule_trigger(id, group) do
    %{
      "id" => id,
      "schedule" => %{"cron" => "0 21 * * *", "timezone" => "Asia/Tokyo"},
      "action" => %{
        "type" => "emit_event",
        "event" => %{"type" => "schedule.fired", "group" => group, "subject" => id}
      }
    }
  end

  defp stochastic_trigger(id, group) do
    %{
      "id" => id,
      "stochastic" => %{
        "distribution" => "shifted_exponential",
        "mean_interval" => "8h",
        "minimum_interval" => "2h"
      },
      "action" => %{
        "type" => "emit_event",
        "event" => %{"type" => "stochastic.fired", "group" => group, "subject" => id}
      }
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

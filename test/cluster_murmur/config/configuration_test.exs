defmodule ClusterMurmur.Config.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Configuration, DocumentSet, LLM, LoadedDocument, Manifest}
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

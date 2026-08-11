defmodule ClusterMurmur.Runtime.ProductionApplicationTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.{
    HealthServer,
    HealthSettings,
    ProductionApplication,
    ReadyMarker,
    RecoveredRuntimeSupervisor
  }

  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    root = PrivateTmpDir.create!("cluster-murmur-production-application-test")
    config_root = Path.join(root, "config")
    config_path = Path.join(config_root, "cluster-murmur.yaml")
    File.mkdir_p!(config_root)

    File.write!(config_path, manifest())

    File.write!(Path.join(config_root, "routing.yaml"), """
    routing:
      default:
        webhook_secret_file_env: DISCORD_WEBHOOK_SECRET_FILE
    """)

    context = %{
      config_path: config_path,
      api_key_path: write(root, "api-key", "clearly-fake-api-key\n"),
      observer_token_path: write(root, "observer-token", "clearly-fake-observer-token\n"),
      webhook_path: write(root, "webhook", webhook_url() <> "\n")
    }

    on_exit(fn -> File.rm_rf!(root) end)
    context
  end

  test "builds the complete ordered production child list without starting it", context do
    assert {:ok,
            [
              {HealthServer, %HealthSettings{port: 18_080}},
              {ReadyMarker, :production},
              ClusterMurmur.Repo,
              {RecoveredRuntimeSupervisor, %RecoveredRuntimeSupervisor.Options{} = options}
            ]} = result = ProductionApplication.child_specs(environment(context))

    assert RecoveredRuntimeSupervisor.validate(options) == :ok

    for hidden <- [
          "clearly-fake-api-key",
          "clearly-fake-observer-token",
          "observer.example.invalid",
          "llm.example.invalid",
          webhook_url(),
          context.config_path,
          context.webhook_path
        ] do
      refute inspect(result) =~ hidden
    end
  end

  test "returns only a stable error for invalid configuration path inputs", context do
    values = environment_values(context)

    invalid_values = [
      Map.delete(values, "CLUSTER_MURMUR_CONFIG_PATH"),
      Map.put(values, "CLUSTER_MURMUR_CONFIG_PATH", "relative/config.yaml"),
      Map.put(values, "CLUSTER_MURMUR_CONFIG_PATH", "/" <> String.duplicate("a", 4_096))
    ]

    for candidate <- invalid_values do
      assert ProductionApplication.child_specs(environment(candidate)) ==
               {:error, :invalid_production_application}
    end
  end

  test "fails closed for malformed readers and startup settings", context do
    assert ProductionApplication.child_specs(:not_an_environment_reader) ==
             {:error, :invalid_production_application}

    invalid_intervals =
      context
      |> environment_values()
      |> Map.put("CLUSTER_MURMUR_POLL_INTERVAL", "0s")

    assert ProductionApplication.child_specs(environment(invalid_intervals)) ==
             {:error, :invalid_production_application}

    invalid_health =
      context
      |> environment_values()
      |> Map.put("CLUSTER_MURMUR_HEALTH_PORT", "0")

    assert ProductionApplication.child_specs(environment(invalid_health)) ==
             {:error, :invalid_production_application}
  end

  defp environment(context) when is_map(context) do
    values =
      if Map.has_key?(context, :config_path),
        do: environment_values(context),
        else: context

    fn name -> Map.fetch(values, name) end
  end

  defp environment_values(context) do
    %{
      "CLUSTER_MURMUR_CONFIG_PATH" => context.config_path,
      "CLUSTER_MURMUR_HEALTH_PORT" => "18080",
      "CLUSTER_MURMUR_OBSERVER_MCP_URL" => "https://observer.example.invalid/mcp",
      "CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE" => context.observer_token_path,
      "LLM_BASE_URL" => "https://llm.example.invalid/v1",
      "LLM_MODEL" => "example-model",
      "LLM_API_KEY_FILE" => context.api_key_path,
      "DISCORD_WEBHOOK_SECRET_FILE" => context.webhook_path,
      "CLUSTER_MURMUR_POLL_INTERVAL" => "30s",
      "CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL" => "2s",
      "CLUSTER_MURMUR_RECURRING_INTERVAL" => "10s",
      "CLUSTER_MURMUR_STOCHASTIC_INTERVAL" => "15s",
      "CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL" => "1h",
      "CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL" => "5s",
      "CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY" => "0ms",
      "CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY" => "1s",
      "CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY" => "2s"
    }
  end

  defp manifest do
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
      event_groups: []
      personas: []
      bindings: []
      triggers: []
      routing:
        - routing.yaml
    """
  end

  defp webhook_url, do: "https://discord.com/api/webhooks/123456789/clearly_fake_token"

  defp write(root, name, contents) do
    path = Path.join(root, name)
    File.write!(path, contents)
    path
  end
end

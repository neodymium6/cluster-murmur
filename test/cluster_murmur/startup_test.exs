defmodule ClusterMurmur.StartupTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.Startup
  alias ClusterMurmur.Startup.Prepared
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    root = PrivateTmpDir.create!("cluster-murmur-startup-test")
    config_root = Path.join(root, "config")
    config_path = Path.join(config_root, "cluster-murmur.yaml")
    File.mkdir_p!(config_root)

    File.write!(config_path, manifest())

    File.write!(Path.join(config_root, "routing.yaml"), """
    routing:
      default:
        webhook_secret_file_env: DISCORD_WEBHOOK_SECRET_FILE
    """)

    api_key_path = write(root, "api-key", "clearly-fake-api-key\n")
    webhook_path = write(root, "webhook", webhook_url() <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      api_key_path: api_key_path,
      config_path: config_path,
      webhook_path: webhook_path
    }
  end

  test "prepares one redacted startup value without starting external work", context do
    assert {:ok, %Prepared{} = prepared} =
             Startup.prepare(context.config_path, environment(context))

    assert %Configuration{version: 1} = prepared.configuration

    assert prepared.configuration.state_tracking ==
             %StateTracking{failures_required: 3, successes_required: 4}

    assert %RuntimeSettings{} = prepared.runtime_settings
    assert Startup.validate(prepared) == :ok
    assert inspect(prepared) == "#ClusterMurmur.Startup.Prepared<...>"

    for hidden <- [
          "clearly-fake-api-key",
          "example-model",
          webhook_url(),
          context.api_key_path,
          context.webhook_path
        ] do
      refute inspect(prepared) =~ hidden
    end
  end

  test "stops after configuration failure without reading deployment settings", context do
    File.write!(context.config_path, "[broken")
    parent = self()
    observing_reader = fn _name -> send(parent, :environment_read) end

    assert Startup.prepare(context.config_path, observing_reader) ==
             {:error, {:configuration, {:document, :invalid_yaml}}}

    refute_received :environment_read
  end

  test "labels runtime settings failures after configuration succeeds", context do
    missing_model = context |> environment_values() |> Map.delete("LLM_MODEL")

    assert Startup.prepare(context.config_path, environment(missing_model)) ==
             {:error, {:runtime_settings, {:provider, :missing_provider_model}}}

    missing_webhook =
      context
      |> environment_values()
      |> Map.delete("DISCORD_WEBHOOK_SECRET_FILE")

    assert Startup.prepare(context.config_path, environment(missing_webhook)) ==
             {:error, {:runtime_settings, {:webhook, {:webhook, :missing_secret_file_path}}}}
  end

  test "fails closed for invalid inputs and forged prepared values", context do
    assert Startup.prepare(context.config_path, :not_an_environment_reader) ==
             {:error, :invalid_startup}

    assert {:ok, prepared} = Startup.prepare(context.config_path, environment(context))

    for value <- [
          nil,
          %{prepared | configuration: %{prepared.configuration | version: 1.0}},
          %{prepared | runtime_settings: nil},
          Map.put(prepared, :private, true)
        ] do
      assert Startup.validate(value) == {:error, :invalid_startup}
    end
  end

  defp environment(%{api_key_path: _api_key_path, webhook_path: _webhook_path} = context),
    do: context |> environment_values() |> environment()

  defp environment(values) when is_map(values) do
    fn name -> Map.fetch(values, name) end
  end

  defp environment_values(context) do
    %{
      "LLM_BASE_URL" => "https://llm.example.invalid/v1",
      "LLM_MODEL" => "example-model",
      "LLM_API_KEY_FILE" => context.api_key_path,
      "DISCORD_WEBHOOK_SECRET_FILE" => context.webhook_path
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

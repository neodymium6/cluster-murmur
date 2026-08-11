defmodule ClusterMurmur.RuntimeSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Bindings, Configuration, EventGroups, LLM, Personas}
  alias ClusterMurmur.Config.{Routing, StateTracking, Triggers}
  alias ClusterMurmur.Discord.WebhookSettings
  alias ClusterMurmur.Generation.ProviderSettings
  alias ClusterMurmur.Observers.MCPSettings
  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    root = PrivateTmpDir.create!("cluster-murmur-runtime-settings-test")
    api_key_path = write(root, "api-key", "clearly-fake-api-key\n")
    observer_token_path = write(root, "observer-token", "clearly-fake-observer-token\n")
    webhook_path = write(root, "webhook", webhook_url() <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      api_key_path: api_key_path,
      observer_token_path: observer_token_path,
      webhook_path: webhook_path
    }
  end

  test "loads one redacted aggregate without an external connection", context do
    assert {:ok, %RuntimeSettings{} = settings} =
             RuntimeSettings.load(configuration(), environment(context))

    assert %ProviderSettings{
             base_url: "https://llm.example.invalid/v1",
             model: "example-model",
             api_key: "clearly-fake-api-key"
           } = settings.provider_settings

    assert %MCPSettings{
             endpoint: "https://observer.example.invalid/mcp",
             bearer_token: "clearly-fake-observer-token"
           } = settings.observer_settings

    assert %WebhookSettings{url: url} = settings.webhook_settings
    assert url == webhook_url()
    assert inspect(settings) == "#ClusterMurmur.RuntimeSettings<...>"

    for hidden <- [
          url,
          "clearly-fake-api-key",
          "clearly-fake-observer-token",
          "https://observer.example.invalid/mcp",
          "example-model"
        ] do
      refute inspect(settings) =~ hidden
    end
  end

  test "labels observer, provider, and webhook startup failures", context do
    missing_observer_endpoint =
      context
      |> environment_values()
      |> Map.delete("CLUSTER_MURMUR_OBSERVER_MCP_URL")

    assert RuntimeSettings.load(configuration(), environment(missing_observer_endpoint)) ==
             {:error, {:observer, :missing_mcp_endpoint}}

    missing_observer_token =
      context
      |> environment_values()
      |> Map.delete("CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE")

    assert RuntimeSettings.load(configuration(), environment(missing_observer_token)) ==
             {:error, {:observer, {:bearer_token, :missing_secret_file_path}}}

    missing_model = context |> environment_values() |> Map.delete("LLM_MODEL")

    assert RuntimeSettings.load(configuration(), environment(missing_model)) ==
             {:error, {:provider, :missing_provider_model}}

    missing_webhook =
      context
      |> environment_values()
      |> Map.delete("DISCORD_WEBHOOK_SECRET_FILE")

    assert RuntimeSettings.load(configuration(), environment(missing_webhook)) ==
             {:error, {:webhook, {:webhook, :missing_secret_file_path}}}
  end

  test "fails closed for invalid inputs and raised environment readers" do
    valid = runtime_settings()
    parent = self()
    observing_reader = fn _name -> send(parent, :environment_read) end

    for value <- [
          nil,
          %{configuration() | version: 1.0},
          %{configuration() | event_groups: nil},
          Map.put(configuration(), :private, true)
        ] do
      assert RuntimeSettings.load(value, observing_reader) ==
               {:error, :invalid_runtime_settings}
    end

    refute_received :environment_read

    assert RuntimeSettings.load(configuration(), :not_an_environment_reader) ==
             {:error, :invalid_runtime_settings}

    assert RuntimeSettings.load(configuration(), fn _name -> raise "private diagnostic" end) ==
             {:error, {:observer, :invalid_mcp_settings}}

    assert RuntimeSettings.validate(valid) == :ok

    for value <- [
          nil,
          %{
            valid
            | observer_settings: %{
                valid.observer_settings
                | endpoint: "http://example.invalid/mcp"
              }
          },
          %{valid | provider_settings: %{valid.provider_settings | model: ""}},
          %{valid | webhook_settings: %WebhookSettings{url: "https://example.invalid"}},
          Map.put(valid, :private, true)
        ] do
      assert RuntimeSettings.validate(value) == {:error, :invalid_runtime_settings}
    end
  end

  defp configuration do
    %Configuration{
      version: 1,
      event_groups: %EventGroups{groups: %{}},
      personas: %Personas{personas: %{}},
      bindings: %Bindings{bindings: %{}},
      triggers: %Triggers{triggers: %{}},
      routing: %Routing{webhook_secret_file_env: "DISCORD_WEBHOOK_SECRET_FILE"},
      state_tracking: StateTracking.default(),
      llm: %LLM{
        provider: :openai_compatible,
        base_url_env: "LLM_BASE_URL",
        model_env: "LLM_MODEL",
        api_key_file_env: "LLM_API_KEY_FILE",
        timeout_ms: 20_000,
        max_output_tokens: 300
      }
    }
  end

  defp runtime_settings do
    %RuntimeSettings{
      observer_settings: %MCPSettings{
        endpoint: "https://observer.example.invalid/mcp",
        bearer_token: "clearly-fake-observer-token"
      },
      provider_settings: %ProviderSettings{
        provider: :openai_compatible,
        base_url: "https://llm.example.invalid/v1",
        model: "example-model",
        api_key: "clearly-fake-api-key",
        timeout_ms: 20_000,
        max_output_tokens: 300
      },
      webhook_settings: %WebhookSettings{url: webhook_url()}
    }
  end

  defp environment(
         %{
           api_key_path: _api_key_path,
           observer_token_path: _observer_token_path,
           webhook_path: _webhook_path
         } = context
       ),
       do: context |> environment_values() |> environment()

  defp environment(values) when is_map(values) do
    fn name ->
      case Map.fetch(values, name) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end
  end

  defp environment_values(context) do
    %{
      "CLUSTER_MURMUR_OBSERVER_MCP_URL" => "https://observer.example.invalid/mcp",
      "CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE" => context.observer_token_path,
      "LLM_BASE_URL" => "https://llm.example.invalid/v1",
      "LLM_MODEL" => "example-model",
      "LLM_API_KEY_FILE" => context.api_key_path,
      "DISCORD_WEBHOOK_SECRET_FILE" => context.webhook_path
    }
  end

  defp webhook_url, do: "https://discord.com/api/webhooks/123456789/clearly_fake_token"

  defp write(root, name, contents) do
    path = Path.join(root, name)
    File.write!(path, contents)
    path
  end
end

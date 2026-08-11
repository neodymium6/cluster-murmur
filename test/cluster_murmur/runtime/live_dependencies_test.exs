defmodule ClusterMurmur.Runtime.LiveDependenciesTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{WebhookPublisher, WebhookSettings}
  alias ClusterMurmur.Generation.{OpenAICompatibleProvider, ProviderSettings}
  alias ClusterMurmur.Observers.{Client, MCPClient, MCPSettings}
  alias ClusterMurmur.Runtime.LiveDependencies
  alias ClusterMurmur.Runtime.SchedulerSettings
  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.Startup.Prepared
  alias ClusterMurmur.TestSupport.RuntimeFixture

  test "builds only the fixed narrow live capabilities without connecting" do
    prepared = prepared()

    assert {:ok, %LiveDependencies{} = dependencies} = LiveDependencies.build(prepared)
    assert %Client{adapter: MCPClient, context: observer_transport} = dependencies.observer_client
    assert dependencies.provider == OpenAICompatibleProvider
    assert dependencies.publisher == WebhookPublisher
    assert is_function(observer_transport, 1)
    assert is_function(dependencies.generation_transport, 1)
    assert is_function(dependencies.publication_transport, 1)

    assert observer_transport.(nil) == {:error, :rejected, :invalid_request}
    assert dependencies.generation_transport.(nil) == {:error, :invalid_response}

    assert dependencies.publication_transport.(nil) ==
             {:error, :not_sent, :invalid_request}
  end

  test "keeps captured endpoints and credentials out of inspection" do
    assert {:ok, dependencies} = LiveDependencies.build(prepared())
    inspected = inspect(dependencies)

    assert inspected =~ "observer_client: #ClusterMurmur.Observers.Client<adapter:"
    assert inspected =~ "provider: ClusterMurmur.Generation.OpenAICompatibleProvider"
    assert inspected =~ "publisher: ClusterMurmur.Discord.WebhookPublisher"

    for hidden <- [
          "observer.example.invalid",
          "clearly-fake-observer-token",
          "llm.example.invalid",
          "clearly-fake-api-key",
          "clearly-fake-webhook-token"
        ] do
      refute inspected =~ hidden
    end
  end

  test "rejects invalid or extended prepared startup values" do
    valid = prepared()

    for candidate <- [
          nil,
          %{valid | runtime_settings: nil},
          %{
            valid
            | runtime_settings: %{
                valid.runtime_settings
                | observer_settings: %{
                    valid.runtime_settings.observer_settings
                    | endpoint: "http://example.invalid/mcp"
                  }
              }
          },
          Map.put(valid, :private, true)
        ] do
      assert LiveDependencies.build(candidate) == {:error, :invalid_live_dependencies}
    end
  end

  defp prepared do
    %Prepared{
      configuration: RuntimeFixture.configuration(),
      scheduler_settings: %SchedulerSettings{
        poll_interval_ms: 30_000,
        event_dispatch_interval_ms: 2_000,
        recurring_interval_ms: 10_000,
        stochastic_interval_ms: 15_000,
        event_retention_interval_ms: 3_600_000
      },
      runtime_settings: %RuntimeSettings{
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
        webhook_settings: %WebhookSettings{
          url: "https://discord.com/api/webhooks/1/clearly-fake-webhook-token"
        }
      }
    }
  end
end

defmodule ClusterMurmur.Runtime.ProductionConversationRuntimeTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.WebhookSettings
  alias ClusterMurmur.Generation.ProviderSettings
  alias ClusterMurmur.Observers.{Client, MCPSettings}

  alias ClusterMurmur.Persistence.{EventDispatchStore, EventStore}

  alias ClusterMurmur.Runtime.{
    EventDispatchCycle,
    LiveDependencies,
    PollStarterCycle,
    ProductionConversationRuntime,
    ResponderScheduleSettings,
    SchedulerSettings
  }

  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.Startup.Prepared
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer

  test "builds one shared preflighted production conversation runtime" do
    prepared = prepared()

    assert {:ok, %ProductionConversationRuntime{} = runtime} =
             ProductionConversationRuntime.build(prepared)

    poll = runtime.poll_context
    dispatch = runtime.event_dispatch_context

    assert poll.shared_input === dispatch.shared_input
    assert poll.shared_input.configuration === prepared.configuration
    assert poll.shared_input.cooldowns == %{}
    assert poll.shared_input.provider_settings === prepared.runtime_settings.provider_settings
    assert poll.shared_input.webhook_settings === prepared.runtime_settings.webhook_settings
    assert is_function(poll.shared_input.generation_transport, 1)
    assert is_function(poll.shared_input.publication_transport, 1)

    assert poll.adapters === dispatch.adapters
    assert poll.conversation_runtime.schedule === dispatch.conversation_runtime.schedule
    assert poll.conversation_runtime.adapters === dispatch.conversation_runtime.adapters
    assert poll.conversation_runtime.adapters.starter === poll.adapters

    assert {:ok, live} = LiveDependencies.build(prepared)
    assert poll.adapters.provider === live.provider
    assert poll.adapters.publisher === live.publisher
    assert poll.conversation_runtime.adapters.responder.provider === live.provider
    assert poll.conversation_runtime.adapters.responder.publisher === live.publisher

    assert ProductionConversationRuntime.validate_live_adapters(
             live,
             poll.conversation_runtime.adapters
           ) == :ok

    assert %EventDispatchCycle.Adapters{
             dispatches: EventDispatchStore,
             events: EventStore,
             authorizer: EventTriggerAuthorizer
           } = runtime.event_dispatch_adapters

    assert Client.validate(runtime.observer_client) == :ok
    assert PollStarterCycle.validate_runtime(prepared.configuration, poll) == :ok

    assert EventDispatchCycle.validate_runtime(
             prepared.configuration,
             dispatch,
             runtime.event_dispatch_adapters
           ) == :ok
  end

  test "keeps captured live settings and capabilities out of inspection" do
    assert {:ok, runtime} = ProductionConversationRuntime.build(prepared())
    inspected = inspect(runtime)

    assert inspected == "#ClusterMurmur.Runtime.ProductionConversationRuntime<...>"

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

  test "fails closed for invalid startup and unschedulable conversation inputs" do
    valid = prepared()

    invalid = [
      nil,
      Map.put(valid, :private, true),
      %{valid | runtime_settings: nil},
      %{
        valid
        | configuration: %{
            valid.configuration
            | conversation_defaults: %{
                valid.configuration.conversation_defaults
                | max_turns: 258
              }
          }
      },
      %{
        valid
        | responder_schedule_settings: %{
            valid.responder_schedule_settings
            | generation_delay_ms: 3_000
          }
      }
    ]

    for candidate <- invalid do
      assert ProductionConversationRuntime.build(candidate) ==
               {:error, :invalid_production_conversation_runtime}
    end
  end

  test "rejects live provider and publisher identities that drift from conversation adapters" do
    assert {:ok, runtime} = ProductionConversationRuntime.build(prepared())
    assert {:ok, live} = LiveDependencies.build(prepared())
    adapters = runtime.poll_context.conversation_runtime.adapters

    for mismatched <- [
          %{live | provider: String},
          %{live | publisher: String},
          Map.put(live, :private, true),
          nil
        ] do
      assert ProductionConversationRuntime.validate_live_adapters(mismatched, adapters) ==
               {:error, :invalid_production_conversation_runtime}
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
      responder_schedule_settings: %ResponderScheduleSettings{
        turn_interval_ms: 5_000,
        generation_delay_ms: 0,
        publication_start_delay_ms: 1_000,
        publication_complete_delay_ms: 2_000
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

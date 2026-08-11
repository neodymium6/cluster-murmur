defmodule ClusterMurmur.Runtime.ProductionConversationSchedulerOptionsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.WebhookSettings
  alias ClusterMurmur.Generation.ProviderSettings
  alias ClusterMurmur.Observers.MCPSettings
  alias ClusterMurmur.Persistence.ObservationIngestionStore

  alias ClusterMurmur.Runtime.{
    EventDispatchCycle,
    EventDispatchScheduler,
    PollScheduler,
    ProductionConversationSchedulerOptions,
    ResponderScheduleSettings,
    SchedulerSettings,
    SystemClock
  }

  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.Startup.Prepared
  alias ClusterMurmur.TestSupport.RuntimeFixture

  test "builds exact validated options for both production conversation schedulers" do
    prepared = prepared()

    assert {:ok, %ProductionConversationSchedulerOptions{} = options} =
             ProductionConversationSchedulerOptions.build(prepared)

    assert %PollScheduler.Options{
             configuration: configuration,
             ingestion_store: ObservationIngestionStore,
             clock: SystemClock,
             interval_ms: 30_000,
             initial_delay_ms: 30_000
           } = options.poll

    assert configuration === prepared.configuration

    assert %EventDispatchScheduler.Options{
             configuration: ^configuration,
             cycle: EventDispatchCycle,
             clock: SystemClock,
             interval_ms: 2_000,
             initial_delay_ms: 2_000
           } = options.event_dispatch

    assert PollScheduler.validate(options.poll) == :ok
    assert EventDispatchScheduler.validate(options.event_dispatch) == :ok

    assert options.poll.cycle_context.shared_input ===
             options.event_dispatch.cycle_context.shared_input

    assert options.poll.cycle_context.conversation_runtime.schedule ===
             options.event_dispatch.cycle_context.conversation_runtime.schedule
  end

  test "keeps settings and capabilities out of aggregate inspection" do
    assert {:ok, options} = ProductionConversationSchedulerOptions.build(prepared())
    inspected = inspect(options)

    assert inspected == "#ClusterMurmur.Runtime.ProductionConversationSchedulerOptions<...>"

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

  test "fails closed for malformed startup and cadence values" do
    valid = prepared()

    for candidate <- [
          nil,
          Map.put(valid, :private, true),
          %{valid | scheduler_settings: nil},
          %{
            valid
            | scheduler_settings: %{valid.scheduler_settings | poll_interval_ms: 0}
          },
          %{
            valid
            | scheduler_settings: %{
                valid.scheduler_settings
                | event_dispatch_interval_ms: 0
              }
          }
        ] do
      assert ProductionConversationSchedulerOptions.build(candidate) ==
               {:error, :invalid_production_conversation_scheduler_options}
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

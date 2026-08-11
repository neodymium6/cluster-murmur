defmodule ClusterMurmur.Runtime.ProductionBackgroundSchedulerOptionsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.WebhookSettings
  alias ClusterMurmur.Generation.ProviderSettings
  alias ClusterMurmur.Observers.MCPSettings

  alias ClusterMurmur.Runtime.{
    EventRetentionCycle,
    EventRetentionScheduler,
    ProductionBackgroundSchedulerOptions,
    RecurringScheduleCycle,
    RecurringScheduleScheduler,
    ResponderScheduleSettings,
    SchedulerSettings,
    StochasticCycle,
    StochasticScheduler,
    SystemClock,
    SystemRandom
  }

  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.Startup.Prepared
  alias ClusterMurmur.TestSupport.RuntimeFixture

  test "builds exact validated options for all background schedulers" do
    prepared = prepared()

    assert {:ok, %ProductionBackgroundSchedulerOptions{} = options} =
             ProductionBackgroundSchedulerOptions.build(prepared)

    assert %RecurringScheduleScheduler.Options{
             configuration: configuration,
             cycle: RecurringScheduleCycle,
             clock: SystemClock,
             interval_ms: 10_000,
             initial_delay_ms: 10_000
           } = options.recurring

    assert configuration === prepared.configuration

    assert %StochasticScheduler.Options{
             configuration: ^configuration,
             cycle: StochasticCycle,
             clock: SystemClock,
             random: SystemRandom,
             interval_ms: 15_000,
             initial_delay_ms: 15_000
           } = options.stochastic

    assert %EventRetentionScheduler.Options{
             configuration: ^configuration,
             cycle: EventRetentionCycle,
             clock: SystemClock,
             interval_ms: 3_600_000,
             initial_delay_ms: 3_600_000
           } = options.event_retention

    assert RecurringScheduleScheduler.validate(options.recurring) == :ok
    assert StochasticScheduler.validate(options.stochastic) == :ok
    assert EventRetentionScheduler.validate(options.event_retention) == :ok
  end

  test "fails closed for malformed startup or background cadence values" do
    valid = prepared()

    for candidate <- [
          nil,
          Map.put(valid, :private, true),
          %{valid | scheduler_settings: nil},
          %{valid | scheduler_settings: %{valid.scheduler_settings | recurring_interval_ms: 0}},
          %{valid | scheduler_settings: %{valid.scheduler_settings | stochastic_interval_ms: 0}},
          %{
            valid
            | scheduler_settings: %{valid.scheduler_settings | event_retention_interval_ms: 0}
          }
        ] do
      assert ProductionBackgroundSchedulerOptions.build(candidate) ==
               {:error, :invalid_production_background_scheduler_options}
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

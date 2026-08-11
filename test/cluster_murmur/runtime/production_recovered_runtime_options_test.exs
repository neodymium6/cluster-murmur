defmodule ClusterMurmur.Runtime.ProductionRecoveredRuntimeOptionsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.WebhookSettings
  alias ClusterMurmur.Generation.ProviderSettings
  alias ClusterMurmur.Observers.MCPSettings

  alias ClusterMurmur.Runtime.{
    ProductionRecoveredRuntimeOptions,
    RecoveredRuntimeSupervisor,
    RecurringScheduleInitializer,
    ResponderScheduleSettings,
    SchedulerSettings,
    StochasticScheduleInitializer,
    SystemClock
  }

  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.Startup.Prepared
  alias ClusterMurmur.TestSupport.RuntimeFixture

  test "builds one correlated recovery-gated production option value" do
    prepared = prepared()

    assert {:ok, %RecoveredRuntimeSupervisor.Options{} = options} =
             ProductionRecoveredRuntimeOptions.build(prepared)

    assert options.recurring_schedule_initializer == RecurringScheduleInitializer
    assert options.stochastic_schedule_initializer == StochasticScheduleInitializer
    assert options.clock == SystemClock

    schedulers = [
      options.poll_scheduler,
      options.event_dispatch_scheduler,
      options.recurring_schedule_scheduler,
      options.stochastic_scheduler,
      options.event_retention_scheduler
    ]

    assert Enum.all?(schedulers, &(&1.configuration === prepared.configuration))
    assert Enum.all?(schedulers, &(&1.clock == SystemClock))
    assert RecoveredRuntimeSupervisor.validate(options) == :ok
  end

  test "effect-free preflight rejects extended and decorrelated options" do
    assert {:ok, options} = ProductionRecoveredRuntimeOptions.build(prepared())

    invalid = [
      nil,
      Map.put(options, :private, true),
      %{options | clock: String},
      %{options | recurring_schedule_initializer: String},
      %{
        options
        | event_retention_scheduler: %{
            options.event_retention_scheduler
            | configuration: %{
                options.event_retention_scheduler.configuration
                | version: 1.0
              }
          }
      }
    ]

    for candidate <- invalid do
      assert RecoveredRuntimeSupervisor.validate(candidate) ==
               {:error, :invalid_recovered_runtime_supervisor}
    end
  end

  test "fails closed for malformed prepared startup values" do
    valid = prepared()

    for candidate <- [
          nil,
          Map.put(valid, :private, true),
          %{valid | scheduler_settings: nil},
          %{valid | scheduler_settings: %{valid.scheduler_settings | poll_interval_ms: 0}}
        ] do
      assert ProductionRecoveredRuntimeOptions.build(candidate) ==
               {:error, :invalid_production_recovered_runtime_options}
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

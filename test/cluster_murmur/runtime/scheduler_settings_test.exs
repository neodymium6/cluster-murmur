defmodule ClusterMurmur.Runtime.SchedulerSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Runtime.SchedulerSettings

  test "loads and revalidates every bounded scheduler interval" do
    assert {:ok, %SchedulerSettings{} = settings} = SchedulerSettings.load(environment())

    assert settings == %SchedulerSettings{
             poll_interval_ms: 30_000,
             event_dispatch_interval_ms: 2_000,
             recurring_interval_ms: 10_000,
             stochastic_interval_ms: 15_000,
             event_retention_interval_ms: 3_600_000
           }

    assert SchedulerSettings.validate(settings) == :ok
  end

  test "labels missing values without exposing environment results" do
    values = environment_values()

    cases = [
      {"CLUSTER_MURMUR_POLL_INTERVAL", :missing_poll_interval},
      {"CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL", :missing_event_dispatch_interval},
      {"CLUSTER_MURMUR_RECURRING_INTERVAL", :missing_recurring_interval},
      {"CLUSTER_MURMUR_STOCHASTIC_INTERVAL", :missing_stochastic_interval},
      {"CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL", :missing_event_retention_interval}
    ]

    for {name, error} <- cases do
      assert SchedulerSettings.load(environment(Map.delete(values, name))) == {:error, error}
    end
  end

  test "rejects invalid syntax, busy loops, oversized values, and reader failures" do
    for {name, value, error} <- [
          {"CLUSTER_MURMUR_POLL_INTERVAL", "999ms", :invalid_poll_interval},
          {"CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL", "1", :invalid_event_dispatch_interval},
          {"CLUSTER_MURMUR_RECURRING_INTERVAL", " 10s", :invalid_recurring_interval},
          {"CLUSTER_MURMUR_STOCHASTIC_INTERVAL", String.duplicate("9", 33),
           :invalid_stochastic_interval},
          {"CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL", "59s", :invalid_event_retention_interval},
          {"CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL", "#{DomainLimits.max_interval_ms() + 1}ms",
           :invalid_event_retention_interval}
        ] do
      values = Map.put(environment_values(), name, value)
      assert SchedulerSettings.load(environment(values)) == {:error, error}
    end

    assert SchedulerSettings.load(:not_a_reader) == {:error, :invalid_scheduler_settings}

    assert SchedulerSettings.load(fn _name -> raise "private diagnostic" end) ==
             {:error, :invalid_scheduler_settings}
  end

  test "rejects forged or extended settings" do
    {:ok, valid} = SchedulerSettings.load(environment())

    for candidate <- [
          nil,
          %{valid | poll_interval_ms: 999},
          %{valid | event_retention_interval_ms: 59_999},
          Map.put(valid, :private, true)
        ] do
      assert SchedulerSettings.validate(candidate) == {:error, :invalid_scheduler_settings}
    end
  end

  defp environment(values \\ environment_values()) do
    fn name -> Map.fetch(values, name) end
  end

  defp environment_values do
    %{
      "CLUSTER_MURMUR_POLL_INTERVAL" => "30s",
      "CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL" => "2s",
      "CLUSTER_MURMUR_RECURRING_INTERVAL" => "10s",
      "CLUSTER_MURMUR_STOCHASTIC_INTERVAL" => "15s",
      "CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL" => "1h"
    }
  end
end

defmodule ClusterMurmur.Runtime.ResponderScheduleSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Runtime.ResponderScheduleSettings

  test "loads and revalidates one ordered bounded timing value" do
    assert {:ok, %ResponderScheduleSettings{} = settings} =
             ResponderScheduleSettings.load(environment())

    assert settings == %ResponderScheduleSettings{
             turn_interval_ms: 5_000,
             generation_delay_ms: 0,
             publication_start_delay_ms: 1_000,
             publication_complete_delay_ms: 2_000
           }

    assert ResponderScheduleSettings.validate(settings) == :ok
  end

  test "labels every missing value without exposing reader results" do
    cases = [
      {"CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL", :missing_responder_turn_interval},
      {"CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY", :missing_responder_generation_delay},
      {"CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY",
       :missing_responder_publication_start_delay},
      {"CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY",
       :missing_responder_publication_complete_delay}
    ]

    for {name, error} <- cases do
      values = Map.delete(environment_values(), name)
      assert ResponderScheduleSettings.load(environment(values)) == {:error, error}
    end
  end

  test "rejects malformed, oversized, out-of-range, and unordered timings" do
    for {name, value, error} <- [
          {"CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL", "999ms", :invalid_responder_turn_interval},
          {"CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY", " 0ms",
           :invalid_responder_generation_delay},
          {"CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY", String.duplicate("9", 33),
           :invalid_responder_publication_start_delay},
          {"CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY",
           "#{DomainLimits.max_interval_ms() + 1}ms",
           :invalid_responder_publication_complete_delay}
        ] do
      values = Map.put(environment_values(), name, value)
      assert ResponderScheduleSettings.load(environment(values)) == {:error, error}
    end

    unordered =
      environment_values()
      |> Map.put("CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY", "3s")
      |> Map.put("CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY", "2s")

    assert ResponderScheduleSettings.load(environment(unordered)) ==
             {:error, :invalid_responder_schedule_settings}

    assert ResponderScheduleSettings.load(fn _name -> raise "private diagnostic" end) ==
             {:error, :invalid_responder_schedule_settings}

    assert ResponderScheduleSettings.load(:not_a_reader) ==
             {:error, :invalid_responder_schedule_settings}
  end

  test "rejects forged and extended settings" do
    {:ok, valid} = ResponderScheduleSettings.load(environment())

    for candidate <- [
          nil,
          %{valid | publication_start_delay_ms: 3_000, publication_complete_delay_ms: 2_000},
          %{valid | publication_complete_delay_ms: 5_001},
          Map.put(valid, :private, true)
        ] do
      assert ResponderScheduleSettings.validate(candidate) ==
               {:error, :invalid_responder_schedule_settings}
    end
  end

  defp environment(values \\ environment_values()) do
    fn name -> Map.fetch(values, name) end
  end

  defp environment_values do
    %{
      "CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL" => "5s",
      "CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY" => "0ms",
      "CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY" => "1s",
      "CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY" => "2s"
    }
  end
end

defmodule ClusterMurmur.Runtime.HealthSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.HealthSettings

  test "loads one exact explicit listener port" do
    assert HealthSettings.load(environment(%{"CLUSTER_MURMUR_HEALTH_PORT" => "18080"})) ==
             {:ok, %HealthSettings{port: 18_080}}

    assert HealthSettings.validate(%HealthSettings{port: 18_080}) == :ok
  end

  test "fails closed for missing, malformed, extended, and out-of-range values" do
    for values <- [
          %{},
          %{"CLUSTER_MURMUR_HEALTH_PORT" => ""},
          %{"CLUSTER_MURMUR_HEALTH_PORT" => "0"},
          %{"CLUSTER_MURMUR_HEALTH_PORT" => "65536"},
          %{"CLUSTER_MURMUR_HEALTH_PORT" => "8080 "},
          %{"CLUSTER_MURMUR_HEALTH_PORT" => "not-a-port"}
        ] do
      assert HealthSettings.load(environment(values)) ==
               {:error, :invalid_health_settings}
    end

    valid = %HealthSettings{port: 18_080}

    for candidate <- [nil, %{valid | port: 0}, Map.put(valid, :private, true)] do
      assert HealthSettings.validate(candidate) == {:error, :invalid_health_settings}
    end
  end

  defp environment(values), do: fn name -> Map.fetch(values, name) end
end

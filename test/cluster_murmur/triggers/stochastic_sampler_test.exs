defmodule ClusterMurmur.Triggers.StochasticSamplerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Triggers.{EmittedEvent, StochasticSampler, StochasticTrigger}

  defmodule ZeroRandom do
    def uniform, do: 0.0
  end

  defmodule HalfRandom do
    def uniform, do: 0.5
  end

  defmodule OneRandom do
    def uniform, do: 1.0
  end

  defmodule IntegerRandom do
    def uniform, do: 0
  end

  defmodule RaisingRandom do
    def uniform, do: raise("private random failure")
  end

  test "samples the minimum wait at the lower uniform boundary" do
    assert StochasticSampler.sample_wait(trigger(), ZeroRandom) == {:ok, 2_000}
  end

  test "uses the shifted exponential inverse CDF deterministically" do
    assert StochasticSampler.sample_wait(trigger(), HalfRandom) == {:ok, 6_158}
    assert StochasticSampler.sample_wait(trigger(), HalfRandom) == {:ok, 6_158}
  end

  test "never samples below the configured minimum" do
    for random <- [ZeroRandom, HalfRandom] do
      assert {:ok, wait} = StochasticSampler.sample_wait(trigger(), random)
      assert wait >= trigger().minimum_interval_ms
    end
  end

  test "rejects invalid random adapters and values without exposing details" do
    for random <- [OneRandom, IntegerRandom] do
      assert StochasticSampler.sample_wait(trigger(), random) ==
               {:error, :invalid_random_value}
    end

    for random <- [RaisingRandom, String, nil] do
      result = StochasticSampler.sample_wait(trigger(), random)
      assert result == {:error, :invalid_random_source}
      refute inspect(result) =~ "private"
    end
  end

  test "rejects forged trigger values before sampling" do
    invalid = [
      nil,
      %{trigger() | distribution: :uniform},
      %{trigger() | minimum_interval_ms: 0},
      %{trigger() | mean_interval_ms: 2_000},
      %{trigger() | mean_interval_ms: 1.0},
      %{trigger() | mean_interval_ms: Integer.pow(10, 400)}
    ]

    for trigger <- invalid do
      assert StochasticSampler.sample_wait(trigger, RaisingRandom) == {:error, :invalid_trigger}
    end
  end

  defp trigger do
    %StochasticTrigger{
      id: "ambient",
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: nil,
      daily_limit: nil,
      action: :emit_event,
      event: %EmittedEvent{type: "stochastic.fired", group: "social", subject: "ambient"}
    }
  end
end

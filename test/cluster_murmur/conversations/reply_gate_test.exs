defmodule ClusterMurmur.Conversations.ReplyGateTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.{ReplyGate, ReplyGateDecision}

  defmodule RaisingRandom do
    def uniform, do: raise("private random failure")
  end

  defmodule ZeroRandom do
    def uniform, do: 0.0
  end

  defmodule BelowRandom do
    def uniform, do: 0.249_999
  end

  defmodule ThresholdRandom do
    def uniform, do: 0.25
  end

  defmodule InvalidRandom do
    def uniform, do: 1.0
  end

  defmodule IntegerRandom do
    def uniform, do: 0
  end

  defmodule CountingRandom do
    def uniform do
      Process.put(:reply_gate_sample_count, Process.get(:reply_gate_sample_count, 0) + 1)
      0.1
    end
  end

  test "handles zero and one probabilities without sampling" do
    assert ReplyGate.evaluate(group(0), RaisingRandom) ==
             {:ok, %ReplyGateDecision{outcome: :no_reply}}

    assert ReplyGate.evaluate(group(1), RaisingRandom) ==
             {:ok, %ReplyGateDecision{outcome: :reply}}
  end

  test "allows a sample strictly below the configured probability" do
    assert ReplyGate.evaluate(group(0.25), ZeroRandom) ==
             {:ok, %ReplyGateDecision{outcome: :reply}}

    assert ReplyGate.evaluate(group(0.25), BelowRandom) ==
             {:ok, %ReplyGateDecision{outcome: :reply}}
  end

  test "returns explicit no-reply at and above the probability threshold" do
    assert ReplyGate.evaluate(group(0.25), ThresholdRandom) ==
             {:ok, %ReplyGateDecision{outcome: :no_reply}}
  end

  test "samples exactly once for one intermediate gate" do
    Process.put(:reply_gate_sample_count, 0)

    assert ReplyGate.evaluate(group(0.25), CountingRandom) ==
             {:ok, %ReplyGateDecision{outcome: :reply}}

    assert Process.get(:reply_gate_sample_count) == 1
  end

  test "rejects invalid random adapters and samples without exposing values" do
    for random <- [RaisingRandom, String, nil] do
      result = ReplyGate.evaluate(group(0.25), random)
      assert result == {:error, :invalid_random_source}
      refute inspect(result) =~ "private"
    end

    for random <- [InvalidRandom, IntegerRandom] do
      assert ReplyGate.evaluate(group(0.25), random) == {:error, :invalid_random_value}
    end
  end

  test "rejects malformed exact event groups before sampling" do
    valid = group(0.25)

    for rejected <- [
          nil,
          %{},
          %{valid | id: "invalid id"},
          %{valid | reply_probability: -0.1},
          %{valid | reply_probability: 1.1},
          %{valid | reply_probability: :infinity},
          Map.delete(valid, :id),
          Map.put(valid, :private_value, "private")
        ] do
      result = ReplyGate.evaluate(rejected, RaisingRandom)
      assert result == {:error, :invalid_event_group}
      refute inspect(result) =~ "private"
    end
  end

  test "decision inspection exposes only the bounded outcome" do
    assert {:ok, decision} = ReplyGate.evaluate(group(0), RaisingRandom)
    assert inspect(decision) =~ "no_reply"
    refute inspect(decision) =~ "operations"
  end

  defp group(probability), do: %{id: "operations", reply_probability: probability}
end

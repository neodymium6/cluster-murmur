defmodule ClusterMurmur.Config.EventPolicyTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.EventPolicy

  test "returns and round-trips the bounded version 1 defaults" do
    policy = EventPolicy.default()

    assert policy == %EventPolicy{
             dedupe_window_ms: 300_000,
             retention_ms: 7_776_000_000
           }

    assert EventPolicy.validate(policy) == :ok
    assert {:ok, document} = EventPolicy.to_document(policy)
    assert EventPolicy.parse(document) == {:ok, policy}
  end

  test "normalizes one exact explicit mapping" do
    assert EventPolicy.parse(%{"dedupe_window" => "90s", "retention" => "30d"}) ==
             {:ok, %EventPolicy{dedupe_window_ms: 90_000, retention_ms: 2_592_000_000}}
  end

  test "rejects malformed, extended, inverted, and out-of-range mappings" do
    valid = %{"dedupe_window" => "5m", "retention" => "90d"}

    for invalid <- [
          nil,
          [],
          Map.delete(valid, "dedupe_window"),
          Map.put(valid, "private", true),
          %{valid | "dedupe_window" => "0ms"},
          %{valid | "dedupe_window" => "91d", "retention" => "90d"},
          %{valid | "retention" => "366d"},
          %{valid | "retention" => 90}
        ] do
      assert EventPolicy.parse(invalid) == {:error, :invalid_event_policy}
    end
  end

  test "rejects forged normalized values and document projection fails closed" do
    valid = EventPolicy.default()

    for forged <- [
          nil,
          Map.put(valid, :private, true),
          %{valid | dedupe_window_ms: 0},
          %{valid | dedupe_window_ms: 1.0},
          %{valid | retention_ms: valid.dedupe_window_ms - 1},
          %{valid | retention_ms: 365 * 86_400_000 + 1}
        ] do
      assert EventPolicy.validate(forged) == {:error, :invalid_event_policy}
      assert EventPolicy.to_document(forged) == {:error, :invalid_event_policy}
    end
  end
end

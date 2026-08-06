defmodule ClusterMurmur.Config.StateTrackingTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Observations.DebouncePolicy

  test "provides the fixed version 1 default and its ingestion policy" do
    assert %StateTracking{failures_required: 2, successes_required: 2} =
             state_tracking = StateTracking.default()

    assert StateTracking.validate(state_tracking) == :ok

    assert StateTracking.to_debounce_policy(state_tracking) ==
             {:ok, %DebouncePolicy{healthy_threshold: 2, unhealthy_threshold: 2}}
  end

  test "parses exact bounded failure and success thresholds" do
    assert {:ok, %StateTracking{} = state_tracking} =
             StateTracking.parse(%{
               "failures_required" => 3,
               "successes_required" => 4
             })

    assert state_tracking.failures_required == 3
    assert state_tracking.successes_required == 4

    assert StateTracking.to_debounce_policy(state_tracking) ==
             {:ok, %DebouncePolicy{healthy_threshold: 4, unhealthy_threshold: 3}}

    assert StateTracking.to_document(state_tracking) ==
             {:ok, %{"failures_required" => 3, "successes_required" => 4}}
  end

  test "rejects missing, unknown, unbounded, and incorrectly typed fields" do
    maximum = DomainLimits.max_safe_integer()

    invalid = [
      nil,
      %{},
      %{"failures_required" => 2},
      %{"failures_required" => 2, "successes_required" => 2, "private" => true},
      %{"failures_required" => 0, "successes_required" => 2},
      %{"failures_required" => 2, "successes_required" => -1},
      %{"failures_required" => 2.0, "successes_required" => 2},
      %{"failures_required" => 2, "successes_required" => maximum + 1}
    ]

    for document <- invalid do
      assert StateTracking.parse(document) ==
               {:error, :invalid_state_tracking_configuration}
    end

    assert {:ok, %StateTracking{failures_required: ^maximum, successes_required: ^maximum}} =
             StateTracking.parse(%{
               "failures_required" => maximum,
               "successes_required" => maximum
             })
  end

  test "rejects forged normalized values before policy projection" do
    state_tracking = StateTracking.default()

    for value <- [
          nil,
          %{state_tracking | failures_required: 1.0},
          %{state_tracking | successes_required: 0},
          Map.put(state_tracking, :private, true)
        ] do
      assert StateTracking.validate(value) ==
               {:error, :invalid_state_tracking_configuration}

      assert StateTracking.to_debounce_policy(value) ==
               {:error, :invalid_state_tracking_configuration}

      assert StateTracking.to_document(value) ==
               {:error, :invalid_state_tracking_configuration}
    end
  end
end

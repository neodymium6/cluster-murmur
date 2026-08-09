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

  test "resolves exact subject then source then default overrides" do
    document = %{
      "failures_required" => 2,
      "successes_required" => 3,
      "overrides" => [
        %{
          "source" => "observer.example",
          "failures_required" => 4,
          "successes_required" => 5
        },
        %{
          "source" => "observer.example",
          "subject" => "target-a",
          "failures_required" => 6,
          "successes_required" => 7
        }
      ]
    }

    assert {:ok, %StateTracking{} = state_tracking} = StateTracking.parse(document)
    assert StateTracking.validate(state_tracking) == :ok
    assert map_size(state_tracking.overrides) == 2

    assert StateTracking.resolve(state_tracking, "observer.example", "target-a") ==
             {:ok, %DebouncePolicy{healthy_threshold: 7, unhealthy_threshold: 6}}

    assert StateTracking.resolve(state_tracking, "observer.example", "target-b") ==
             {:ok, %DebouncePolicy{healthy_threshold: 5, unhealthy_threshold: 4}}

    assert StateTracking.resolve(state_tracking, "other.example", "target-a") ==
             {:ok, %DebouncePolicy{healthy_threshold: 3, unhealthy_threshold: 2}}

    assert StateTracking.to_document(state_tracking) == {:ok, document}
    refute inspect(state_tracking) =~ "observer.example"
    refute inspect(state_tracking) =~ "target-a"
  end

  test "rejects malformed, duplicate, and oversized override documents" do
    override = %{
      "source" => "observer.example",
      "failures_required" => 2,
      "successes_required" => 2
    }

    base = %{"failures_required" => 2, "successes_required" => 2}

    invalid_overrides = [
      nil,
      %{},
      [%{"source" => "observer.example"}],
      [Map.put(override, "private", true)],
      [%{override | "source" => ""}],
      [%{override | "source" => "bad\0source"}],
      [%{override | "source" => String.duplicate("s", 16 * 1_024 + 1)}],
      [%{override | "source" => <<255>>}],
      [%{override | "failures_required" => 0}],
      [Map.put(override, "subject", 1)],
      [override, override],
      Enum.map(0..256, fn index ->
        %{override | "source" => "observer-#{index}.example"}
      end),
      [override | "improper"]
    ]

    for overrides <- invalid_overrides do
      assert StateTracking.parse(Map.put(base, "overrides", overrides)) ==
               {:error, :invalid_state_tracking_configuration}
    end
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

    override = %StateTracking.Override{
      source: "observer.example",
      subject: nil,
      failures_required: 2,
      successes_required: 2
    }

    for value <- [
          nil,
          %{state_tracking | failures_required: 1.0},
          %{state_tracking | successes_required: 0},
          %{state_tracking | overrides: %{{"wrong.example", nil} => override}},
          %{
            state_tracking
            | overrides: %{{"observer.example", nil} => Map.put(override, :private, true)}
          },
          Map.put(state_tracking, :private, true)
        ] do
      assert StateTracking.validate(value) ==
               {:error, :invalid_state_tracking_configuration}

      assert StateTracking.to_debounce_policy(value) ==
               {:error, :invalid_state_tracking_configuration}

      assert StateTracking.to_document(value) ==
               {:error, :invalid_state_tracking_configuration}
    end

    assert StateTracking.resolve(state_tracking, "", "target-a") ==
             {:error, :invalid_state_tracking_configuration}
  end
end

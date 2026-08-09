defmodule ClusterMurmur.Events.DedupeEvaluatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.Events.{DedupeEvaluator, Event}
  alias ClusterMurmur.Events.DedupeEvaluator.Marker

  @accepted_at ~U[2026-08-09 01:00:00.000000Z]

  test "accepts a first keyed event and projects one redacted marker" do
    event = event("event-a", "observation.failed:example-target")

    assert {:ok, {:accept, %Marker{} = marker}} =
             result =
             DedupeEvaluator.evaluate(event, nil, policy(), @accepted_at)

    assert result ==
             {:ok,
              {:accept,
               %Marker{
                 dedupe_key: event.dedupe_key,
                 event_id: event.id,
                 accepted_at: @accepted_at
               }}}

    inspected = inspect(marker)

    for hidden <- ["event-a", "example-target", "2026"] do
      refute inspected =~ hidden
    end
  end

  test "does not create markers for events without a dedupe key" do
    assert DedupeEvaluator.evaluate(event("event-a", nil), nil, policy(), @accepted_at) ==
             {:ok, {:accept, nil}}
  end

  test "suppresses a different event only while the marker window is active" do
    first = event("event-a", "observation.failed:example-target")
    repeated = event("event-b", first.dedupe_key)
    marker = marker(first)

    assert DedupeEvaluator.evaluate(
             repeated,
             marker,
             policy(),
             DateTime.add(@accepted_at, 299_999_999, :microsecond)
           ) == {:ok, {:skip, :dedupe_window}}

    boundary = DateTime.add(@accepted_at, 300_000_000, :microsecond)

    assert DedupeEvaluator.evaluate(repeated, marker, policy(), boundary) ==
             {:ok,
              {:accept,
               %Marker{
                 dedupe_key: repeated.dedupe_key,
                 event_id: repeated.id,
                 accepted_at: boundary
               }}}
  end

  test "accepts an exact event retry without extending its marker window" do
    event = event("event-a", "observation.failed:example-target")
    marker = marker(event)
    retried_at = DateTime.add(@accepted_at, 60, :second)

    assert DedupeEvaluator.evaluate(event, marker, policy(), retried_at) ==
             {:ok, {:accept, marker}}
  end

  test "rejects uncorrelated, future, and forged markers" do
    event = event("event-b", "observation.failed:example-target")
    valid = marker(event("event-a", event.dedupe_key))

    invalid_markers = [
      %{valid | dedupe_key: "other-key"},
      %{valid | accepted_at: DateTime.add(@accepted_at, 1, :microsecond)},
      Map.put(valid, :private, "private-value")
    ]

    for marker <- invalid_markers do
      result = DedupeEvaluator.evaluate(event, marker, policy(), @accepted_at)
      assert result == {:error, :invalid_marker}
      refute inspect(result) =~ "private"
    end

    assert DedupeEvaluator.evaluate(event("event-c", nil), valid, policy(), @accepted_at) ==
             {:error, :invalid_marker}
  end

  test "rejects invalid events, policies, and instants without values" do
    event = event("event-a", "observation.failed:example-target")
    invalid_policy = %{policy() | dedupe_window_ms: 0}

    assert DedupeEvaluator.evaluate(%{event | id: ""}, nil, policy(), @accepted_at) ==
             {:error, :invalid_event}

    assert DedupeEvaluator.evaluate(event, nil, invalid_policy, @accepted_at) ==
             {:error, :invalid_event_policy}

    assert DedupeEvaluator.evaluate(event, nil, policy(), nil) ==
             {:error, :invalid_datetime}

    assert DedupeEvaluator.evaluate(%{event | id: ""}, nil, nil, nil) ==
             {:error, :invalid_event}

    assert DedupeEvaluator.evaluate(event, nil, nil, nil) ==
             {:error, :invalid_event_policy}
  end

  defp marker(event) do
    %Marker{dedupe_key: event.dedupe_key, event_id: event.id, accepted_at: @accepted_at}
  end

  defp policy do
    %EventPolicy{dedupe_window_ms: 300_000, retention_ms: 7_776_000_000}
  end

  defp event(id, dedupe_key) do
    %Event{
      id: id,
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      group: "operations",
      severity: "warning",
      previous: "healthy",
      current: "unhealthy",
      occurred_at: @accepted_at,
      observed_at: @accepted_at,
      dedupe_key: dedupe_key,
      correlation_key: nil,
      facts: %{},
      labels: %{}
    }
  end
end

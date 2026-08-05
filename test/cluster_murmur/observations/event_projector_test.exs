defmodule ClusterMurmur.Observations.EventProjectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Validator
  alias ClusterMurmur.Observations.{EntityState, EntityStateValidator, EventProjector}

  test "projects initial and healthy failures with stable bounded facts" do
    for previous <- [nil, state(current_state: :healthy)] do
      next = state(current_state: :unhealthy, last_observed_at: later(), last_changed_at: later())
      assert {:ok, event} = EventProjector.project(previous, next)
      assert Validator.validate(event) == :ok
      assert event.type == "observation.failed"
      assert event.severity == "warning"
      assert event.previous == if(previous == nil, do: "unknown", else: "healthy")
      assert event.current == "unhealthy"
      assert event.occurred_at == later()
      assert event.observed_at == later()
      assert event.facts == next.facts
      assert event.labels == next.labels
      assert String.starts_with?(event.id, "observation-")
      assert String.starts_with?(event.dedupe_key, "observation.failed:")
      assert EventProjector.project(previous, next) == {:ok, event}
    end
  end

  test "projects recoveries and suppresses silent committed transitions" do
    assert {:ok, recovered} =
             EventProjector.project(
               state(current_state: :unhealthy),
               state(current_state: :healthy, last_observed_at: later(), last_changed_at: later())
             )

    assert recovered.type == "observation.recovered"
    assert recovered.severity == "info"

    assert EventProjector.project(
             nil,
             state(current_state: :healthy, last_observed_at: later(), last_changed_at: later())
           ) == :no_event

    assert EventProjector.project(
             state(current_state: :healthy),
             state(current_state: :healthy, last_observed_at: later())
           ) == :no_event

    assert EventProjector.project(
             nil,
             state(
               current_state: :unknown,
               pending_state: :unhealthy,
               consecutive_count: 1,
               last_changed_at: nil
             )
           ) == :no_event
  end

  test "rejects invalid, mismatched, and non-monotonic state pairs" do
    previous = state([])

    invalid = [
      {previous, %{state(last_observed_at: later()) | source: "other"}},
      {previous, state(last_observed_at: previous.last_observed_at)},
      {previous,
       state(
         current_state: :unhealthy,
         pending_state: :healthy,
         consecutive_count: 1,
         last_observed_at: later(),
         last_changed_at: later()
       )},
      {previous,
       state(
         current_state: :unhealthy,
         last_observed_at: later(),
         last_changed_at: previous.last_changed_at
       )},
      {previous, state(last_observed_at: later(), last_changed_at: later())},
      {%{previous | consecutive_count: -1}, state(last_observed_at: later())},
      {previous, %{state(last_observed_at: later()) | facts: []}},
      {nil, nil}
    ]

    for {left, right} <- invalid do
      assert EventProjector.project(left, right) ==
               {:error, :invalid_observation_transition}
    end
  end

  test "canonicalizes equal observation instants in deterministic IDs" do
    precise =
      state(current_state: :unhealthy, last_observed_at: later(), last_changed_at: later())

    coarse_time = %{later() | microsecond: {0, 0}}
    coarse = %{precise | last_observed_at: coarse_time, last_changed_at: coarse_time}

    assert {:ok, precise_event} = EventProjector.project(state([]), precise)
    assert {:ok, coarse_event} = EventProjector.project(state([]), coarse)
    assert precise_event.id == coarse_event.id
  end

  test "projects a recovery at the exact shared text boundary" do
    base =
      state(
        current_state: :healthy,
        last_observed_at: later(),
        last_changed_at: later()
      )

    maximum = largest_valid_payload(base, 0, 64 * 1_024)
    next = %{base | facts: payload(maximum)}

    assert EntityStateValidator.validate(next) == :ok

    assert EntityStateValidator.validate(%{base | facts: payload(maximum + 1)}) ==
             {:error, :invalid_entity_state}

    assert {:ok, event} = EventProjector.project(state(current_state: :unhealthy), next)
    assert Validator.validate(event) == :ok
  end

  test "keeps dedupe keys bounded for maximum-length identities" do
    source = String.duplicate("s", 16 * 1_024)
    subject = String.duplicate("t", 16 * 1_024)

    assert {:ok, event} =
             EventProjector.project(
               state(source: source, subject: subject, current_state: :healthy),
               state(
                 source: source,
                 subject: subject,
                 current_state: :unhealthy,
                 last_observed_at: later(),
                 last_changed_at: later()
               )
             )

    assert byte_size(event.dedupe_key) < 128
  end

  defp later, do: ~U[2026-08-05 12:01:00.000000Z]

  defp largest_valid_payload(base, low, high) when low < high do
    candidate = div(low + high + 1, 2)

    if EntityStateValidator.validate(%{base | facts: payload(candidate)}) == :ok,
      do: largest_valid_payload(base, candidate, high),
      else: largest_valid_payload(base, low, candidate - 1)
  end

  defp largest_valid_payload(_base, value, value), do: value

  defp payload(bytes) do
    full_chunks = div(bytes, 16_000)
    remainder = rem(bytes, 16_000)
    chunks = List.duplicate(String.duplicate("x", 16_000), full_chunks)
    chunks = if remainder == 0, do: chunks, else: chunks ++ [String.duplicate("x", remainder)]
    %{"details" => chunks}
  end

  defp state(overrides) do
    struct!(
      EntityState,
      Keyword.merge(
        [
          source: "example-observer",
          subject: "example-target",
          current_state: :healthy,
          pending_state: nil,
          consecutive_count: 0,
          last_observed_at: ~U[2026-08-05 12:00:00.000000Z],
          last_changed_at: ~U[2026-08-05 11:00:00.000000Z],
          facts: %{"attempts" => 2},
          labels: %{"category" => "monitoring"}
        ],
        overrides
      )
    )
  end
end

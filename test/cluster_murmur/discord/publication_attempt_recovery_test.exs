defmodule ClusterMurmur.Discord.PublicationAttemptRecoveryTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.PublicationAttemptRecovery
  alias ClusterMurmur.Persistence.PublicationAttemptRecord

  test "marks starts at or before the startup cutoff ambiguous instead of retrying" do
    assert PublicationAttemptRecovery.classify(loaded([]), cutoff()) ==
             {:ok, :mark_ambiguous}

    assert PublicationAttemptRecovery.classify(loaded(started_at: cutoff()), cutoff()) ==
             {:ok, :mark_ambiguous}
  end

  test "leaves a start after the startup cutoff to the current process" do
    recent = loaded(started_at: DateTime.add(cutoff(), 1, :microsecond))
    assert PublicationAttemptRecovery.classify(recent, cutoff()) == {:ok, :no_action}
  end

  test "leaves every terminal outcome unchanged" do
    completed_at = ~U[2026-08-05 12:03:00.000000Z]

    terminal = [
      loaded(status: :succeeded, completed_at: completed_at),
      loaded(status: :failed, completed_at: completed_at, error_class: :timeout),
      loaded(status: :ambiguous, completed_at: completed_at, error_class: :interrupted)
    ]

    for attempt <- terminal do
      assert PublicationAttemptRecovery.classify(attempt, cutoff()) == {:ok, :no_action}
    end
  end

  test "fails closed on malformed or untrusted attempts" do
    valid = loaded([])

    for attempt <- [
          nil,
          %PublicationAttemptRecord{},
          %{valid | message_id: 0},
          %{valid | status: :failed, error_class: :interrupted},
          Map.put(valid, :private, true)
        ] do
      assert PublicationAttemptRecovery.classify(attempt, cutoff()) ==
               {:error, :invalid_publication_attempt_record}
    end
  end

  test "rejects an invalid recovery cutoff" do
    for cutoff <- [nil, %{cutoff() | hour: 24}] do
      assert PublicationAttemptRecovery.classify(loaded([]), cutoff) ==
               {:error, :invalid_datetime}
    end
  end

  defp cutoff, do: ~U[2026-08-05 12:02:30.000000Z]

  defp loaded(overrides) do
    struct!(
      PublicationAttemptRecord,
      Keyword.merge(
        [
          __meta__: Ecto.put_meta(%PublicationAttemptRecord{}, state: :loaded).__meta__,
          message_id: 42,
          status: :started,
          started_at: ~U[2026-08-05 12:02:00.000000Z],
          completed_at: nil,
          error_class: nil
        ],
        overrides
      )
    )
  end
end

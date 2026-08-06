defmodule ClusterMurmur.Persistence.PublicationAttemptRecordValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator
  }

  @max_sqlite_integer 9_223_372_036_854_775_807
  @external_errors [
    :authentication_failed,
    :invalid_request,
    :invalid_response,
    :rate_limited,
    :timeout,
    :unavailable
  ]

  test "accepts every exact loaded lifecycle shape" do
    terminal = ~U[2026-08-05 12:03:00.000000Z]

    valid = [
      loaded([]),
      loaded(status: :dispatching),
      loaded(status: :succeeded, completed_at: terminal),
      loaded(status: :failed, completed_at: terminal, error_class: :timeout),
      loaded(status: :ambiguous, completed_at: terminal, error_class: :interrupted)
    ]

    for record <- valid do
      assert PublicationAttemptRecordValidator.validate(record) == :ok
      refute inspect(record) =~ "2026"
      refute inspect(record) =~ Integer.to_string(record.message_id)
    end
  end

  test "accepts every stable external failure class" do
    for error_class <- @external_errors do
      assert PublicationAttemptRecordValidator.validate(
               loaded(
                 status: :failed,
                 completed_at: ~U[2026-08-05 12:03:00.000000Z],
                 error_class: error_class
               )
             ) == :ok
    end
  end

  test "enforces exact loaded metadata and SQLite ID boundaries" do
    assert PublicationAttemptRecordValidator.validate(loaded(message_id: @max_sqlite_integer)) ==
             :ok

    forged_source = Ecto.put_meta(loaded([]), source: "messages")
    forged_prefix = Ecto.put_meta(loaded([]), prefix: "private")

    for value <- [
          loaded(message_id: nil),
          loaded(message_id: -1),
          loaded(message_id: 1.0),
          loaded(message_id: @max_sqlite_integer + 1),
          forged_source,
          forged_prefix
        ] do
      assert PublicationAttemptRecordValidator.validate(value) ==
               {:error, :invalid_publication_attempt_record}
    end
  end

  test "rejects invalid and noncanonical terminal timestamps" do
    for completed_at <- [
          nil,
          %{~U[2026-08-05 12:03:00.000000Z] | hour: 24},
          %{~U[2026-08-05 12:03:00.000000Z] | microsecond: {0, 0}}
        ] do
      assert PublicationAttemptRecordValidator.validate(
               loaded(status: :succeeded, completed_at: completed_at)
             ) == {:error, :invalid_publication_attempt_record}
    end
  end

  test "rejects built, extended, malformed, and miscorrelated records" do
    terminal = ~U[2026-08-05 12:03:00.000000Z]
    valid = loaded([])

    invalid = [
      nil,
      %PublicationAttemptRecord{},
      Map.put(valid, :private, true),
      %{valid | message_id: 0},
      %{valid | status: :started, completed_at: terminal},
      %{valid | status: :dispatching, completed_at: terminal},
      %{valid | status: :succeeded, completed_at: terminal, error_class: :timeout},
      %{valid | status: :failed, completed_at: terminal, error_class: :interrupted},
      %{valid | status: :ambiguous, completed_at: terminal, error_class: :timeout},
      %{
        valid
        | status: :failed,
          completed_at: ~U[2026-08-05 12:01:59.999999Z],
          error_class: :timeout
      },
      %{valid | started_at: %{valid.started_at | microsecond: {0, 0}}}
    ]

    for record <- invalid do
      assert PublicationAttemptRecordValidator.validate(record) ==
               {:error, :invalid_publication_attempt_record}
    end
  end

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

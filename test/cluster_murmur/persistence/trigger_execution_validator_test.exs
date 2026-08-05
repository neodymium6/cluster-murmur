defmodule ClusterMurmur.Persistence.TriggerExecutionValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{TriggerExecution, TriggerExecutionValidator}

  test "accepts exact loaded records in every valid lifecycle state" do
    for execution <- [
          loaded(:started, nil),
          loaded(:completed, nil),
          loaded(:failed, "provider.unavailable")
        ] do
      assert TriggerExecutionValidator.validate(execution) == :ok
    end

    assert TriggerExecutionValidator.validate_started(loaded(:started, nil)) == :ok
  end

  test "started validation rejects terminal records" do
    for execution <- [loaded(:completed, nil), loaded(:failed, "runtime.interrupted")] do
      assert TriggerExecutionValidator.validate_started(execution) ==
               {:error, :invalid_execution}
    end
  end

  test "rejects forged metadata, shapes, IDs, and datetimes" do
    valid = loaded(:started, nil)

    invalid = [
      nil,
      %TriggerExecution{},
      Map.put(valid, :unexpected_private_value, "private"),
      Ecto.put_meta(valid, state: :built),
      Ecto.put_meta(valid, source: "events"),
      Ecto.put_meta(valid, prefix: "private"),
      %{valid | trigger_id: "invalid id"},
      %{valid | event_id: ""},
      %{valid | executed_at: %{valid.executed_at | hour: 24}},
      %{valid | executed_at: %{valid.executed_at | microsecond: {0, 0}}},
      %{valid | cooldown_until: DateTime.add(valid.executed_at, -1, :microsecond)}
    ]

    for execution <- invalid do
      assert TriggerExecutionValidator.validate(execution) == {:error, :invalid_execution}

      assert TriggerExecutionValidator.validate_started(execution) ==
               {:error, :invalid_execution}
    end
  end

  test "enforces status and error-class correlation" do
    invalid = [
      loaded(:started, "provider.unavailable"),
      loaded(:completed, "provider.unavailable"),
      loaded(:failed, nil),
      loaded(:failed, "Invalid Error"),
      loaded(:failed, String.duplicate("a", 129)),
      loaded(:unknown, nil)
    ]

    for execution <- invalid do
      assert TriggerExecutionValidator.validate(execution) == {:error, :invalid_execution}
    end
  end

  defp loaded(status, error_class) do
    %TriggerExecution{
      __meta__: Ecto.put_meta(%TriggerExecution{}, state: :loaded).__meta__,
      trigger_id: "failure-conversation",
      event_id: "example-event",
      status: status,
      executed_at: ~U[2026-08-04 12:00:00.000000Z],
      cooldown_until: ~U[2026-08-04 12:01:00.000000Z],
      error_class: error_class
    }
  end
end

defmodule ClusterMurmur.Triggers.TriggerExecutionRecoveryTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.TriggerExecution
  alias ClusterMurmur.Triggers.TriggerExecutionRecovery

  test "classifies started executions on both sides of the cutoff" do
    cutoff = ~U[2026-08-04 12:00:00.000000Z]

    assert TriggerExecutionRecovery.classify(started(~U[2026-08-04 11:59:59.999999Z]), cutoff) ==
             {:ok, :abandoned}

    assert TriggerExecutionRecovery.classify(started(cutoff), cutoff) == {:ok, :abandoned}

    assert TriggerExecutionRecovery.classify(started(~U[2026-08-04 12:00:00.000001Z]), cutoff) ==
             {:ok, :recent}
  end

  test "classifies both terminal outcomes without changing their facts" do
    for execution <- [
          %{started(~U[2026-08-04 12:00:01.000000Z]) | status: :completed},
          %{
            started(~U[2026-08-04 12:00:01.000000Z])
            | status: :failed,
              error_class: "runtime.interrupted"
          }
        ] do
      assert TriggerExecutionRecovery.classify(execution, ~U[2026-08-04 12:00:00Z]) ==
               {:ok, :terminal}
    end
  end

  test "preserves stable validation errors" do
    valid = started(~U[2026-08-04 12:00:00.000000Z])
    forged_datetime = %{~U[2026-08-04 12:00:00Z] | hour: 24}

    assert TriggerExecutionRecovery.classify(nil, forged_datetime) ==
             {:error, :invalid_execution}

    assert TriggerExecutionRecovery.classify(%{valid | status: :failed}, forged_datetime) ==
             {:error, :invalid_execution}

    assert TriggerExecutionRecovery.classify(valid, forged_datetime) ==
             {:error, :invalid_datetime}
  end

  defp started(executed_at) do
    %TriggerExecution{
      __meta__: Ecto.put_meta(%TriggerExecution{}, state: :loaded).__meta__,
      trigger_id: "failure-conversation",
      event_id: "example-event",
      status: :started,
      executed_at: executed_at,
      cooldown_until: DateTime.add(executed_at, 60, :second),
      error_class: nil
    }
  end
end

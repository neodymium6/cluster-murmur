defmodule ClusterMurmur.Runtime.ResponderTurnScheduleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn
  alias ClusterMurmur.Runtime.ResponderTurnSchedule
  alias ClusterMurmur.Runtime.ResponderTurnSchedule.Step

  @base_at ~U[2026-08-08 12:00:00.000000Z]

  test "projects a fresh exact bounded turn schedule from one base instant" do
    schedule = schedule()

    assert {:ok, [%Turn{} = first, %Turn{} = second]} =
             ResponderTurnSchedule.project(schedule, @base_at)

    assert first.planned_at == @base_at
    assert first.generated_at == ~U[2026-08-08 12:00:01.000000Z]
    assert first.publication_started_at == ~U[2026-08-08 12:00:02.000000Z]
    assert first.publication_completed_at == ~U[2026-08-08 12:00:03.000000Z]
    assert second.planned_at == ~U[2026-08-08 12:00:04.000000Z]
    assert second.publication_completed_at == ~U[2026-08-08 12:00:07.000000Z]
    assert first.generation_transport === hd(schedule.steps).generation_transport
    refute inspect(schedule) =~ "private transport"
  end

  test "rejects malformed, unbounded, overlapping, and forged schedules" do
    valid = schedule()
    [first, second] = valid.steps

    invalid = [
      nil,
      %ResponderTurnSchedule{steps: []},
      %{valid | steps: [Map.put(first, :private, true)]},
      %{valid | steps: [%{first | planned_after_ms: -1}]},
      %{valid | steps: [%{first | generation_transport: :invalid}]},
      %{valid | steps: [first, %{second | planned_after_ms: 2_000}]},
      %{valid | steps: List.duplicate(first, 257)},
      Map.put(valid, :private, true)
    ]

    for rejected <- invalid do
      assert ResponderTurnSchedule.validate(rejected) ==
               {:error, :invalid_responder_turn_schedule}

      assert ResponderTurnSchedule.project(rejected, @base_at) ==
               {:error, :invalid_responder_turn_schedule}
    end

    assert ResponderTurnSchedule.project(valid, DateTime.to_naive(@base_at)) ==
             {:error, :invalid_responder_turn_schedule}

    assert ResponderTurnSchedule.project(valid, ~U[9999-12-31 23:59:59.999999Z]) ==
             {:error, :invalid_responder_turn_schedule}
  end

  defp schedule do
    %ResponderTurnSchedule{
      steps: [
        step(0, 1_000, 2_000, 3_000),
        step(4_000, 5_000, 6_000, 7_000)
      ]
    }
  end

  defp step(planned, generated, publication_started, publication_completed) do
    %Step{
      planned_after_ms: planned,
      generated_after_ms: generated,
      publication_started_after_ms: publication_started,
      publication_completed_after_ms: publication_completed,
      generation_transport: fn _request -> {:error, "private transport"} end,
      publication_transport: fn _request -> {:error, "private transport"} end
    }
  end
end

defmodule ClusterMurmur.Runtime.ResponderTurnScheduleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ConversationDefaults
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Runtime.ResponderScheduleSettings
  alias ClusterMurmur.Runtime.ResponderConversationRunner
  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn
  alias ClusterMurmur.Runtime.ResponderTurnSchedule
  alias ClusterMurmur.Runtime.ResponderTurnSchedule.Step

  @base_at ~U[2026-08-08 12:00:00.000000Z]

  test "builds one complete finite schedule from conversation and deployment bounds" do
    generation_transport = fn _request -> {:error, :generation_not_called} end
    publication_transport = fn _request -> {:error, :publication_not_called} end

    assert {:ok, %ResponderTurnSchedule{steps: [first, second]} = schedule} =
             ResponderTurnSchedule.build(
               ConversationDefaults.default(),
               settings(),
               generation_transport,
               publication_transport
             )

    assert %Step{
             planned_after_ms: 0,
             generated_after_ms: 1_000,
             publication_started_after_ms: 2_000,
             publication_completed_after_ms: 3_000
           } = first

    assert %Step{
             planned_after_ms: 4_000,
             generated_after_ms: 5_000,
             publication_started_after_ms: 6_000,
             publication_completed_after_ms: 7_000
           } = second

    assert first.generation_transport === generation_transport
    assert second.publication_transport === publication_transport
    assert ResponderTurnSchedule.validate(schedule) == :ok

    assert {:ok, turns} = ResponderTurnSchedule.project(schedule, @base_at)

    deadline =
      DateTime.add(@base_at, ConversationDefaults.default().max_duration_ms, :millisecond)

    assert ResponderConversationRunner.validate_schedule(turns, @base_at, deadline) == :ok
  end

  test "keeps a single terminalization step when the starter exhausts the turn budget" do
    defaults = %{ConversationDefaults.default() | max_turns: 1}

    assert {:ok, %ResponderTurnSchedule{steps: [%Step{}]}} =
             ResponderTurnSchedule.build(defaults, settings(), transport(), transport())
  end

  test "rejects schedules that cannot stay finite and valid for the conversation" do
    valid_defaults = ConversationDefaults.default()
    valid_settings = settings()
    generation_transport = transport()
    publication_transport = transport()

    invalid_inputs = [
      {%{valid_defaults | max_turns: 258}, valid_settings, generation_transport,
       publication_transport},
      {%{valid_defaults | max_duration_ms: 1_000}, %{valid_settings | generation_delay_ms: 1_000},
       generation_transport, publication_transport},
      {%{valid_defaults | max_turns: 4},
       %{
         valid_settings
         | turn_interval_ms: DomainLimits.max_interval_ms(),
           generation_delay_ms: 0,
           publication_start_delay_ms: 0,
           publication_complete_delay_ms: 0
       }, generation_transport, publication_transport},
      {Map.put(valid_defaults, :private, true), valid_settings, generation_transport,
       publication_transport},
      {valid_defaults, Map.put(valid_settings, :private, true), generation_transport,
       publication_transport},
      {valid_defaults, valid_settings, :invalid, publication_transport}
    ]

    for {defaults, schedule_settings, generation, publication} <- invalid_inputs do
      assert ResponderTurnSchedule.build(
               defaults,
               schedule_settings,
               generation,
               publication
             ) == {:error, :invalid_responder_turn_schedule}
    end
  end

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

  defp settings do
    %ResponderScheduleSettings{
      turn_interval_ms: 4_000,
      generation_delay_ms: 1_000,
      publication_start_delay_ms: 2_000,
      publication_complete_delay_ms: 3_000
    }
  end

  defp transport, do: fn _request -> {:error, :not_called} end

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

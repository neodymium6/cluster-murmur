defmodule ClusterMurmur.Triggers.EmittedEventProjectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Validator
  alias ClusterMurmur.Triggers.{EmittedEvent, EmittedEventProjector}

  @scheduled_at ~U[2026-08-08 13:15:00.123Z]

  test "projects an exact bounded event from one scheduled trigger version" do
    assert {:ok, event} =
             EmittedEventProjector.project(
               :stochastic,
               "occasional-murmur",
               template(),
               @scheduled_at
             )

    assert Validator.validate(event) == :ok
    assert event.type == "stochastic.fired"
    assert event.source == "stochastic"
    assert event.subject == "ambient-conversation"
    assert event.group == "social"
    assert event.severity == "info"
    assert event.previous == nil
    assert event.current == nil
    assert DateTime.compare(event.occurred_at, @scheduled_at) == :eq
    assert event.occurred_at.microsecond == {123_000, 6}
    assert event.observed_at == nil
    assert event.facts == %{}

    assert event.labels == %{
             "trigger_id" => "occasional-murmur",
             "trigger_kind" => "stochastic"
           }

    assert event.id =~ ~r/^stochastic-[0-9a-f]{64}$/
    assert event.dedupe_key =~ ~r/^stochastic:[0-9a-f]{64}$/

    assert EmittedEventProjector.project(
             :stochastic,
             "occasional-murmur",
             template(),
             @scheduled_at
           ) == {:ok, event}

    inspected = inspect(event)
    refute inspected =~ "occasional-murmur"
    refute inspected =~ "ambient-conversation"
  end

  test "separates schedule kinds and scheduled versions deterministically" do
    assert {:ok, stochastic} =
             EmittedEventProjector.project(
               :stochastic,
               "occasional-murmur",
               template(),
               @scheduled_at
             )

    assert {:ok, schedule} =
             EmittedEventProjector.project(
               :schedule,
               "occasional-murmur",
               template(),
               @scheduled_at
             )

    assert {:ok, later} =
             EmittedEventProjector.project(
               :stochastic,
               "occasional-murmur",
               template(),
               DateTime.add(@scheduled_at, 1, :microsecond)
             )

    assert schedule.source == "schedule"
    refute stochastic.id == schedule.id
    refute stochastic.id == later.id
    assert stochastic.dedupe_key == later.dedupe_key
    refute stochastic.dedupe_key == schedule.dedupe_key
  end

  test "preserves the scheduled identity when template drift changes immutable facts" do
    assert {:ok, original} =
             EmittedEventProjector.project(
               :stochastic,
               "occasional-murmur",
               template(),
               @scheduled_at
             )

    changed_template = %{template() | subject: "changed-ambient-conversation"}

    assert {:ok, changed} =
             EmittedEventProjector.project(
               :stochastic,
               "occasional-murmur",
               changed_template,
               @scheduled_at
             )

    assert changed.id == original.id
    refute changed == original
    assert changed.subject == "changed-ambient-conversation"
  end

  test "rejects malformed inputs without returning configured identifiers" do
    forged_time = %{~U[2026-08-08 13:15:00Z] | hour: 24}

    invalid = [
      {:timer, "occasional-murmur", template(), @scheduled_at},
      {:stochastic, "invalid trigger", template(), @scheduled_at},
      {:stochastic, "occasional-murmur", %{template() | group: "invalid group"}, @scheduled_at},
      {:stochastic, "occasional-murmur", Map.put(template(), :private, true), @scheduled_at},
      {:stochastic, "occasional-murmur", template(), forged_time},
      {:stochastic, "occasional-murmur", template(), nil}
    ]

    for arguments <- invalid do
      result = apply(EmittedEventProjector, :project, Tuple.to_list(arguments))
      assert result == {:error, :invalid_emitted_event}
      refute inspect(result) =~ "occasional-murmur"
    end
  end

  defp template do
    %EmittedEvent{
      type: "stochastic.fired",
      group: "social",
      subject: "ambient-conversation"
    }
  end
end

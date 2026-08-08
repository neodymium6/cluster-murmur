defmodule ClusterMurmur.Triggers.EventTriggerBatchAuthorizerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerBatchAuthorizer}
  alias ClusterMurmur.Triggers.EventTriggerBatchAuthorizer.Result

  @executed_at ~U[2026-08-06 19:30:00.000000Z]

  defmodule FakeAuthorizer do
    def authorize(trigger, event, executed_at) do
      Process.put({__MODULE__, :calls}, calls() ++ [trigger.id])

      case Map.get(Process.get({__MODULE__, :responses}, %{}), trigger.id, :build) do
        :build ->
          ClusterMurmur.Triggers.EventTriggerAuthorizer.authorize(
            trigger,
            event,
            executed_at,
            ClusterMurmur.Triggers.EventTriggerBatchAuthorizerTest.FakeStore
          )

        :raise ->
          raise "private authorizer diagnostic"

        response ->
          response
      end
    end

    defp calls, do: Process.get({__MODULE__, :calls}, [])
  end

  defmodule FakeStore do
    def start(plan) do
      {:ok,
       %ClusterMurmur.Persistence.TriggerExecution{
         trigger_id: plan.trigger.id,
         event_id: plan.event.id,
         status: :started,
         executed_at: plan.executed_at,
         cooldown_until: plan.cooldown_until,
         error_class: nil
       }
       |> Ecto.put_meta(state: :loaded)}
    end
  end

  setup do
    Process.put({FakeAuthorizer, :calls}, [])
    Process.put({FakeAuthorizer, :responses}, %{})
    :ok
  end

  test "selects and authorizes matching triggers once in stable order" do
    triggers = [
      trigger("z-recovery", "observation.recovered"),
      trigger("b-failure", "observation.failed"),
      trigger("a-failure", "observation.failed")
    ]

    assert {:ok, %Result{} = result} =
             EventTriggerBatchAuthorizer.authorize_matching(
               triggers,
               event(),
               @executed_at,
               FakeAuthorizer
             )

    assert result.selected_count == 2
    assert result.authorized_count == 2
    assert result.skipped_count == 0
    assert result.failure_count == 0
    assert Enum.map(result.authorizations, & &1.plan.trigger.id) == ["a-failure", "b-failure"]
    assert result.skips == []
    assert result.failures == []
    assert Process.get({FakeAuthorizer, :calls}) == ["a-failure", "b-failure"]
    assert EventTriggerBatchAuthorizer.validate_result(result, triggers) == :ok

    inspected = inspect(result)
    refute inspected =~ "failure-conversation"
    refute inspected =~ event().id
    refute inspected =~ "private"
  end

  test "continues through stable skips and contained authorization failures" do
    triggers = Enum.map(~w(a b c d e), &trigger(&1, "observation.failed"))

    Process.put(
      {FakeAuthorizer, :responses},
      %{
        "a" => {:skip, :cooldown},
        "b" => {:skip, :execution_in_progress},
        "c" => {:error, :event_not_found},
        "d" => {:error, {:private, "diagnostic"}}
      }
    )

    assert {:ok, result} =
             EventTriggerBatchAuthorizer.authorize_matching(
               Enum.reverse(triggers),
               event(),
               @executed_at,
               FakeAuthorizer
             )

    assert result.selected_count == 5
    assert result.authorized_count == 1
    assert result.skipped_count == 2
    assert result.failure_count == 2
    assert Enum.map(result.authorizations, & &1.plan.trigger.id) == ["e"]
    assert result.skips == [:cooldown, :execution_in_progress]
    assert result.failures == [:event_not_found, :authorization_failed]
    assert Process.get({FakeAuthorizer, :calls}) == ~w(a b c d e)
  end

  test "rejects malformed batch inputs before authorizing a trigger" do
    valid = trigger("valid", "observation.failed")

    assert EventTriggerBatchAuthorizer.authorize_matching(
             [valid, valid],
             event(),
             @executed_at,
             FakeAuthorizer
           ) == {:error, :duplicate_trigger}

    assert EventTriggerBatchAuthorizer.authorize_matching(
             [valid],
             nil,
             @executed_at,
             FakeAuthorizer
           ) == {:error, :invalid_event}

    assert EventTriggerBatchAuthorizer.authorize_matching(
             [valid],
             event(),
             nil,
             FakeAuthorizer
           ) == {:error, :invalid_datetime}

    assert EventTriggerBatchAuthorizer.authorize_matching(
             [valid],
             event(),
             @executed_at,
             String
           ) == {:error, :invalid_batch_authorization}

    assert EventTriggerBatchAuthorizer.authorize_matching(
             [valid],
             event(),
             @executed_at,
             fn -> :ok end
           ) == {:error, :invalid_batch_authorization}

    oversized = Enum.map(1..257, &trigger("trigger-#{&1}", "observation.failed"))

    assert EventTriggerBatchAuthorizer.authorize_matching(
             oversized,
             event(),
             @executed_at,
             FakeAuthorizer
           ) == {:error, :too_many_triggers}

    assert EventTriggerBatchAuthorizer.authorize_matching(
             [valid | :tail],
             event(),
             @executed_at,
             FakeAuthorizer
           ) == {:error, :invalid_trigger}

    assert Process.get({FakeAuthorizer, :calls}) == []
  end

  test "contains contradictory, forged, and raised authorizer outcomes" do
    valid = trigger("valid", "observation.failed")
    different = trigger("different", "observation.failed")

    assert {:ok, unrelated} =
             ClusterMurmur.Triggers.EventTriggerAuthorizer.authorize(
               different,
               event(),
               @executed_at,
               FakeStore
             )

    for response <- [
          {:ok, unrelated},
          {:ok, nil},
          {:skip, :not_matched},
          {:error, :private_failure},
          :raise
        ] do
      Process.put({FakeAuthorizer, :responses}, %{"valid" => response})

      assert {:ok, result} =
               EventTriggerBatchAuthorizer.authorize_matching(
                 [valid],
                 event(),
                 @executed_at,
                 FakeAuthorizer
               )

      assert result.authorized_count == 0
      assert result.failure_count == 1
      assert result.failures == [:authorization_failed]
    end
  end

  test "revalidates exact results with bounded proper collections" do
    assert {:ok, valid} =
             EventTriggerBatchAuthorizer.authorize_matching(
               [],
               event(),
               @executed_at,
               FakeAuthorizer
             )

    assert EventTriggerBatchAuthorizer.validate_result(valid, []) == :ok

    for forged <- [
          nil,
          Map.put(valid, :private, true),
          %{valid | selected_count: 1},
          %{valid | skips: [:private], selected_count: 1, skipped_count: 1},
          %{
            valid
            | selected_count: 256,
              failure_count: 256,
              failures: List.duplicate(:authorization_failed, 257)
          },
          %{
            valid
            | selected_count: 1,
              failure_count: 1,
              failures: [:authorization_failed | :tail]
          },
          %{valid | event: %{valid.event | facts: []}}
        ] do
      assert EventTriggerBatchAuthorizer.validate_result(forged, []) ==
               {:error, :invalid_batch_authorization}
    end

    configured_trigger = trigger("configured", "observation.failed")
    configured = [configured_trigger]

    assert {:ok, configured_result} =
             EventTriggerBatchAuthorizer.authorize_matching(
               configured,
               event(),
               @executed_at,
               FakeAuthorizer
             )

    assert {:ok, removed_authorization} =
             ClusterMurmur.Triggers.EventTriggerAuthorizer.authorize(
               trigger("removed", "observation.failed"),
               event(),
               @executed_at,
               FakeStore
             )

    substituted = %{configured_result | authorizations: [removed_authorization]}

    assert EventTriggerBatchAuthorizer.validate_result(substituted, configured) ==
             {:error, :invalid_batch_authorization}

    altered_trigger = %{configured_trigger | binding: "other-characters"}

    assert {:ok, altered_authorization} =
             ClusterMurmur.Triggers.EventTriggerAuthorizer.authorize(
               altered_trigger,
               event(),
               @executed_at,
               FakeStore
             )

    same_id_substituted = %{configured_result | authorizations: [altered_authorization]}

    assert EventTriggerBatchAuthorizer.validate_result(same_id_substituted, configured) ==
             {:error, :invalid_batch_authorization}
  end

  defp trigger(id, type) do
    %EventTrigger{
      id: id,
      matcher: %Matcher{
        predicates: [%Predicate{field: "type", operator: :equals, value: type}]
      },
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: 60_000
    }
  end

  defp event do
    %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      severity: "warning",
      occurred_at: ~U[2026-08-06 19:29:59.000000Z],
      facts: %{"detail" => "private"}
    }
  end
end

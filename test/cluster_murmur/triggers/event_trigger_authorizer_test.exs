defmodule ClusterMurmur.Triggers.EventTriggerAuthorizerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Persistence.TriggerExecution
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerAuthorizer}
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization

  @executed_at ~U[2026-08-06 18:30:00.000000Z]

  defmodule FakeStore do
    def start(plan) do
      Process.put({__MODULE__, :calls}, calls() ++ [plan])

      case Process.get({__MODULE__, :response}, :build) do
        :build -> {:ok, execution(plan)}
        :raise -> raise "private storage diagnostic"
        response -> response
      end
    end

    def execution(plan) do
      %ClusterMurmur.Persistence.TriggerExecution{
        trigger_id: plan.trigger.id,
        event_id: plan.event.id,
        status: :started,
        executed_at: plan.executed_at,
        cooldown_until: plan.cooldown_until,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)
    end

    defp calls, do: Process.get({__MODULE__, :calls}, [])
  end

  setup do
    Process.put({FakeStore, :calls}, [])
    Process.put({FakeStore, :response}, :build)
    :ok
  end

  test "durably authorizes one matching trigger without executing its action" do
    trigger = trigger()
    event = event()

    assert {:ok, %Authorization{} = authorization} =
             EventTriggerAuthorizer.authorize(trigger, event, @executed_at, FakeStore)

    assert authorization.plan.trigger === trigger
    assert authorization.plan.event === event
    assert authorization.execution.trigger_id == trigger.id
    assert authorization.execution.event_id == event.id
    assert authorization.execution.status == :started
    assert EventTriggerAuthorizer.validate(authorization) == :ok
    assert Process.get({FakeStore, :calls}) == [authorization.plan]

    inspected = inspect(authorization)
    refute inspected =~ trigger.id
    refute inspected =~ event.id
    refute inspected =~ "private"
    refute inspected =~ "2026"
  end

  test "returns stable skips for nonmatches, cooldowns, and repeated pairs" do
    nonmatching = %{event() | type: "observation.recovered"}

    assert EventTriggerAuthorizer.authorize(trigger(), nonmatching, @executed_at, FakeStore) ==
             {:skip, :not_matched}

    assert Process.get({FakeStore, :calls}) == []

    for {response, expected} <- [
          {{:skip, :cooldown}, {:skip, :cooldown}},
          {{:error, :execution_conflict}, {:skip, :already_started}}
        ] do
      Process.put({FakeStore, :response}, response)

      assert EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, FakeStore) ==
               expected
    end
  end

  test "preserves only public store errors and contains private failures" do
    for reason <- [:event_conflict, :event_not_found, :invalid_execution, :storage_unavailable] do
      Process.put({FakeStore, :response}, {:error, reason})

      assert EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, FakeStore) ==
               {:error, reason}
    end

    Process.put({FakeStore, :response}, {:error, {:private, "diagnostic"}})

    assert EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, FakeStore) ==
             {:error, :storage_unavailable}

    Process.put({FakeStore, :response}, :raise)

    assert EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, FakeStore) ==
             {:error, :storage_unavailable}
  end

  test "rejects invalid boundaries before calling the store" do
    assert EventTriggerAuthorizer.authorize(nil, event(), @executed_at, FakeStore) ==
             {:error, :invalid_trigger}

    assert EventTriggerAuthorizer.authorize(trigger(), nil, @executed_at, FakeStore) ==
             {:error, :invalid_event}

    assert EventTriggerAuthorizer.authorize(trigger(), event(), nil, FakeStore) ==
             {:error, :invalid_datetime}

    assert EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, String) ==
             {:error, :invalid_authorization}

    assert EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, fn -> :ok end) ==
             {:error, :invalid_authorization}

    assert Process.get({FakeStore, :calls}) == []
  end

  test "rejects forged store capabilities and authorization values" do
    assert {:ok, authorization} =
             EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, FakeStore)

    mismatched = %{authorization.execution | event_id: "different-event"}
    Process.put({FakeStore, :response}, {:ok, mismatched})

    assert EventTriggerAuthorizer.authorize(trigger(), event(), @executed_at, FakeStore) ==
             {:error, :invalid_authorization}

    for forged <- [
          nil,
          Map.put(authorization, :private, true),
          %{authorization | plan: Map.put(authorization.plan, :private, true)},
          %{authorization | execution: mismatched},
          %{authorization | execution: %TriggerExecution{}}
        ] do
      assert EventTriggerAuthorizer.validate(forged) == {:error, :invalid_authorization}
    end
  end

  defp trigger do
    %EventTrigger{
      id: "failure-conversation",
      matcher: %Matcher{
        predicates: [
          %Predicate{field: "type", operator: :equals, value: "observation.failed"}
        ]
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
      occurred_at: ~U[2026-08-06 18:29:59.000000Z],
      facts: %{"detail" => "private"}
    }
  end
end

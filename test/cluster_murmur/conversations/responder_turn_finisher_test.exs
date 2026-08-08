defmodule ClusterMurmur.Conversations.ResponderTurnFinisherTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.ResponderContinuationConsumer
  alias ClusterMurmur.Conversations.ResponderTurnFinisher
  alias ClusterMurmur.Conversations.ResponderTurnFinisher.{Completed, Continuation}

  alias ClusterMurmur.Discord.{
    ResponderPublicationExecutor,
    ResponderPublicationPlanner,
    ResponderPublicationStarter
  }

  alias ClusterMurmur.Discord.ResponderPublicationExecutor.Outcome

  alias ClusterMurmur.Persistence.{
    PersonaCooldownRecord,
    PublicationAttemptRecord
  }

  alias ClusterMurmur.Personas.ResponderCooldownRecorder
  alias ClusterMurmur.Personas.ResponderCooldownRecorder.Recorded
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @started_at ~U[2026-08-07 02:00:05.000000Z]
  @completed_at ~U[2026-08-07 02:00:06.000000Z]
  @cooldown_until ~U[2026-08-07 02:01:06.000000Z]

  defmodule FakeStore do
    def wait(conversation) do
      Process.put({__MODULE__, :input}, {:wait, conversation})
      {:ok, %{conversation | status: :waiting}}
    end

    def complete(conversation, completed_at) do
      Process.put({__MODULE__, :input}, {:complete, conversation, completed_at})
      {:ok, %{conversation | status: :completed, completed_at: completed_at}}
    end
  end

  defmodule ConflictingStore do
    def wait(_conversation), do: {:error, :conversation_conflict}
    def complete(_conversation, _completed_at), do: {:error, :conversation_conflict}
  end

  defmodule WrongStore do
    def wait(conversation), do: {:ok, %{conversation | status: :generating}}

    def complete(conversation, completed_at) do
      {:ok, %{conversation | status: :completed, completed_at: DateTime.add(completed_at, 1)}}
    end
  end

  defmodule RaisingStore do
    def wait(_conversation), do: raise("private storage diagnostic")
    def complete(_conversation, _completed_at), do: raise("private storage diagnostic")
  end

  setup do
    Process.delete({FakeStore, :input})
    :ok
  end

  test "returns an exact waiting continuation while core budget remains" do
    {configuration, cooldowns, settings, recorded} = scenario(3)

    assert {:continue, %Continuation{} = continuation} =
             ResponderTurnFinisher.finish(
               recorded,
               configuration,
               cooldowns,
               settings,
               FakeStore
             )

    active = recorded.published.started.plan.delivery.conversation
    assert Process.get({FakeStore, :input}) === {:wait, active}
    assert continuation.conversation === %{active | status: :waiting}
    assert continuation.runtime.status == :waiting
    assert continuation.runtime.turn_count == active.turn_count
    assert continuation.runtime.llm_call_count == active.llm_call_count
    assert continuation.runtime.participants == ["caretaker", "responder"]
    assert List.last(continuation.runtime.messages).discord_message_id == "23456"
    assert continuation.current_cooldowns["caretaker"] === cooldowns["caretaker"]
    assert continuation.current_cooldowns["responder"] === recorded.cooldown
    assert continuation.budget_state.open?

    assert ResponderTurnFinisher.validate_continuation(
             continuation,
             configuration,
             cooldowns,
             settings
           ) == :ok

    inspected = inspect(continuation)
    refute inspected =~ recorded.published.message.content
    refute inspected =~ "fake-token"
  end

  test "completes at the durable publication instant when core budget is exhausted" do
    {configuration, cooldowns, settings, recorded} = scenario(2)

    assert {:ok, %Completed{} = completed} =
             ResponderTurnFinisher.finish(
               recorded,
               configuration,
               cooldowns,
               settings,
               FakeStore
             )

    active = recorded.published.started.plan.delivery.conversation
    assert Process.get({FakeStore, :input}) === {:complete, active, @completed_at}

    assert completed.conversation === %{
             active
             | status: :completed,
               completed_at: @completed_at
           }

    assert completed.runtime.status == :completed
    refute completed.budget_state.open?
    assert :turns in completed.budget_state.exhausted
    assert ResponderTurnFinisher.validate(completed, configuration, cooldowns, settings) == :ok
  end

  test "prunes unconfigured entries before adding a responder to a full cooldown snapshot" do
    input = RuntimeFixture.responder_input()

    full_cooldowns =
      Enum.reduce(1..255, input.current_cooldowns, fn index, cooldowns ->
        persona_id = "extra-#{index}"

        cooldown =
          %PersonaCooldownRecord{
            persona_id: persona_id,
            last_spoken_at: ~U[2026-08-07 01:00:00.000000Z],
            cooldown_until: ~U[2026-08-07 01:00:01.000000Z]
          }
          |> Ecto.put_meta(state: :loaded)

        Map.put(cooldowns, persona_id, cooldown)
      end)

    assert map_size(full_cooldowns) == 256
    refute Map.has_key?(full_cooldowns, "responder")

    {configuration, cooldowns, settings, recorded} = scenario(3, full_cooldowns)

    assert {:continue, continuation} = finish(recorded, configuration, cooldowns, settings)
    assert Map.keys(continuation.current_cooldowns) |> Enum.sort() == ["caretaker", "responder"]
    assert continuation.current_cooldowns["responder"] === recorded.cooldown
  end

  test "rejects forged or stale upstream capabilities before storage" do
    {configuration, cooldowns, settings, recorded} = scenario(3)

    for candidate <- [
          Map.put(recorded, :private, true),
          %{recorded | cooldown: %{recorded.cooldown | persona_id: "other"}},
          %{recorded | published: %{recorded.published | status: :failed, message: nil}}
        ] do
      assert ResponderTurnFinisher.finish(
               candidate,
               configuration,
               cooldowns,
               settings,
               FakeStore
             ) == {:error, :invalid_responder_turn_completion}
    end

    assert ResponderTurnFinisher.finish(
             recorded,
             configuration,
             %{},
             settings,
             FakeStore
           ) == {:error, :invalid_responder_turn_completion}

    assert Process.get({FakeStore, :input}) == nil
  end

  test "preserves conflicts, rejects mismatched records, and contains diagnostics" do
    {configuration, cooldowns, settings, recorded} = scenario(3)

    assert ResponderTurnFinisher.finish(
             recorded,
             configuration,
             cooldowns,
             settings,
             ConflictingStore
           ) == {:error, :conversation_conflict}

    assert ResponderTurnFinisher.finish(
             recorded,
             configuration,
             cooldowns,
             settings,
             WrongStore
           ) == {:error, :invalid_conversation_record}

    result =
      ResponderTurnFinisher.finish(
        recorded,
        configuration,
        cooldowns,
        settings,
        RaisingStore
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  test "rejects forged continuation and terminal capabilities" do
    {configuration, cooldowns, settings, open_recorded} = scenario(3)
    assert {:continue, continuation} = finish(open_recorded, configuration, cooldowns, settings)

    for forged <- [
          nil,
          Map.put(continuation, :private, true),
          %{continuation | runtime: %{continuation.runtime | turn_count: 1}},
          %{continuation | conversation: %{continuation.conversation | status: :generating}},
          %{continuation | current_cooldowns: cooldowns}
        ] do
      assert ResponderTurnFinisher.validate_continuation(
               forged,
               configuration,
               cooldowns,
               settings
             ) == {:error, :invalid_responder_turn_completion}
    end

    {configuration, cooldowns, settings, closed_recorded} = scenario(2)
    assert {:ok, completed} = finish(closed_recorded, configuration, cooldowns, settings)

    for forged <- [
          nil,
          Map.put(completed, :private, true),
          %{completed | runtime: %{completed.runtime | status: :waiting}},
          %{completed | conversation: %{completed.conversation | turn_count: 1}},
          %{completed | budget_state: %{completed.budget_state | open?: true}}
        ] do
      assert ResponderTurnFinisher.validate(forged, configuration, cooldowns, settings) ==
               {:error, :invalid_responder_turn_completion}
    end
  end

  defp finish(recorded, configuration, cooldowns, settings) do
    ResponderTurnFinisher.finish(recorded, configuration, cooldowns, settings, FakeStore)
  end

  defp scenario(max_turns, supplied_cooldowns \\ nil) do
    configuration = RuntimeFixture.responder_configuration()
    input = RuntimeFixture.responder_input(configuration)
    delivery = RuntimeFixture.responder_delivery(configuration)
    selection_cooldowns = supplied_cooldowns || input.current_cooldowns

    plan_input = %{
      delivery.plan.input
      | budget: %{delivery.plan.input.budget | max_turns: max_turns},
        current_cooldowns: selection_cooldowns
    }

    responder_plan = %{delivery.plan | input: plan_input}
    delivery = %{delivery | plan: responder_plan}
    :ok = ResponderContinuationConsumer.validate_delivery(delivery, responder_plan)

    {:ok, publication_plan} =
      ResponderPublicationPlanner.plan(
        delivery,
        configuration,
        selection_cooldowns,
        input.webhook_settings
      )

    started_attempt =
      %PublicationAttemptRecord{
        message_id: delivery.message.id,
        status: :started,
        started_at: @started_at,
        completed_at: nil,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    started = %ResponderPublicationStarter.Started{
      plan: publication_plan,
      attempt: started_attempt
    }

    attempt = %{
      started_attempt
      | status: :succeeded,
        completed_at: @completed_at,
        error_class: nil
    }

    published = %Outcome{
      started: started,
      attempt: attempt,
      message: %{delivery.message | discord_message_id: "23456"},
      status: :succeeded,
      error_class: nil
    }

    :ok =
      ResponderPublicationExecutor.validate(
        published,
        configuration,
        selection_cooldowns,
        input.webhook_settings
      )

    cooldown =
      %PersonaCooldownRecord{
        persona_id: "responder",
        last_spoken_at: @completed_at,
        cooldown_until: @cooldown_until
      }
      |> Ecto.put_meta(state: :loaded)

    recorded = %Recorded{published: published, cooldown: cooldown}

    :ok =
      ResponderCooldownRecorder.validate(
        recorded,
        configuration,
        selection_cooldowns,
        input.webhook_settings
      )

    {configuration, selection_cooldowns, input.webhook_settings, recorded}
  end
end

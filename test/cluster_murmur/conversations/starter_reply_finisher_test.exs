defmodule ClusterMurmur.Conversations.StarterReplyFinisherTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.StarterReplyFinisher
  alias ClusterMurmur.Conversations.StarterReplyFinisher.{Completed, Continuation}
  alias ClusterMurmur.Discord.{StarterPublicationExecutor, StarterPublicationPlanner}
  alias ClusterMurmur.Discord.StarterPublicationExecutor.Outcome
  alias ClusterMurmur.Discord.StarterPublicationStarter.Started

  alias ClusterMurmur.Persistence.{
    PersonaCooldownRecord,
    PublicationAttemptRecord
  }

  alias ClusterMurmur.Personas.StarterCooldownRecorder.Recorded
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @started_at ~U[2026-08-07 02:00:02.000000Z]
  @completed_at ~U[2026-08-07 02:00:03.000000Z]
  @cooldown_until ~U[2026-08-07 02:01:03.000000Z]

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
      {:ok,
       %{
         conversation
         | status: :completed,
           completed_at: DateTime.add(completed_at, 1, :second)
       }}
    end
  end

  defmodule RaisingStore do
    def wait(_conversation), do: raise("private storage diagnostic")
    def complete(_conversation, _completed_at), do: raise("private storage diagnostic")
  end

  defmodule RaisingRandom do
    def uniform, do: raise("must not sample endpoint probability")
  end

  setup do
    Process.delete({FakeStore, :input})
    :ok
  end

  test "closes the exact advanced conversation after deterministic no reply" do
    {configuration, settings, recorded} = scenario()

    assert {:ok, %Completed{} = completed} =
             StarterReplyFinisher.finish(
               recorded,
               configuration,
               %{},
               settings,
               RaisingRandom,
               FakeStore
             )

    active = recorded.published.started.plan.persisted.conversation
    assert Process.get({FakeStore, :input}) === {:complete, active, @completed_at}
    assert completed.recorded === recorded
    assert completed.decision.outcome == :no_reply
    assert completed.conversation.status == :completed
    assert completed.conversation.completed_at == @completed_at
    assert StarterReplyFinisher.validate(completed, configuration, %{}, settings) == :ok

    inspected = inspect(completed)
    refute inspected =~ recorded.published.message.content
    refute inspected =~ "fake-token"
  end

  test "returns an explicit reply only after durably waiting the conversation" do
    {configuration, settings, recorded} = scenario()

    configuration =
      put_in(
        configuration.event_groups.groups["operations"].reply_probability,
        1
      )

    assert {:continue, :reply, %Continuation{} = continuation} =
             StarterReplyFinisher.finish(
               recorded,
               configuration,
               %{},
               settings,
               RaisingRandom,
               FakeStore
             )

    assert continuation.recorded === recorded

    assert continuation.conversation === %{
             recorded.published.started.plan.persisted.conversation
             | status: :waiting
           }

    assert StarterReplyFinisher.validate_continuation(
             continuation,
             configuration,
             %{},
             settings
           ) == :ok

    assert Process.get({FakeStore, :input}) ===
             {:wait, recorded.published.started.plan.persisted.conversation}
  end

  test "rejects forged upstream capabilities before reply policy or storage" do
    {configuration, settings, recorded} = scenario()

    for candidate <- [
          Map.put(recorded, :private, true),
          %{recorded | cooldown: %{recorded.cooldown | persona_id: "other"}},
          %{
            recorded
            | published: %{recorded.published | status: :failed, message: nil}
          }
        ] do
      assert StarterReplyFinisher.finish(
               candidate,
               configuration,
               %{},
               settings,
               RaisingRandom,
               FakeStore
             ) == {:error, :invalid_starter_completion}
    end

    assert Process.get({FakeStore, :input}) == nil
  end

  test "preserves conflicts and rejects mismatched completion records" do
    {configuration, settings, recorded} = scenario()

    assert StarterReplyFinisher.finish(
             recorded,
             configuration,
             %{},
             settings,
             RaisingRandom,
             ConflictingStore
           ) == {:error, :conversation_conflict}

    assert StarterReplyFinisher.finish(
             recorded,
             configuration,
             %{},
             settings,
             RaisingRandom,
             WrongStore
           ) == {:error, :invalid_conversation_record}
  end

  test "contains storage diagnostics and rejects forged terminal capabilities" do
    {configuration, settings, recorded} = scenario()

    result =
      StarterReplyFinisher.finish(
        recorded,
        configuration,
        %{},
        settings,
        RaisingRandom,
        RaisingStore
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"

    assert {:ok, completed} =
             StarterReplyFinisher.finish(
               recorded,
               configuration,
               %{},
               settings,
               RaisingRandom,
               FakeStore
             )

    always_reply =
      put_in(
        configuration.event_groups.groups["operations"].reply_probability,
        1
      )

    assert StarterReplyFinisher.validate(completed, always_reply, %{}, settings) ==
             {:error, :invalid_starter_completion}

    for forged <- [
          nil,
          Map.put(completed, :private, true),
          %{completed | decision: %{completed.decision | outcome: :reply}},
          %{completed | conversation: %{completed.conversation | turn_count: 2}},
          %{
            completed
            | conversation: %{
                completed.conversation
                | completed_at: DateTime.add(@completed_at, 1, :second)
              }
          }
        ] do
      assert StarterReplyFinisher.validate(forged, configuration, %{}, settings) ==
               {:error, :invalid_starter_completion}
    end
  end

  defp scenario do
    configuration = RuntimeFixture.configuration()
    settings = RuntimeFixture.webhook_settings()
    persisted = RuntimeFixture.persisted(configuration)
    {:ok, plan} = StarterPublicationPlanner.plan(persisted, configuration, %{}, settings)

    started_attempt =
      %PublicationAttemptRecord{
        message_id: persisted.message.id,
        status: :started,
        started_at: @started_at,
        completed_at: nil,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    attempt = %{
      started_attempt
      | status: :succeeded,
        completed_at: @completed_at,
        error_class: nil
    }

    published = %Outcome{
      started: %Started{plan: plan, attempt: started_attempt},
      attempt: attempt,
      message: %{persisted.message | discord_message_id: "12345"},
      status: :succeeded,
      error_class: nil
    }

    assert StarterPublicationExecutor.validate(published, configuration, %{}, settings) == :ok

    cooldown =
      %PersonaCooldownRecord{
        persona_id: persisted.message.persona_id,
        last_spoken_at: @completed_at,
        cooldown_until: @cooldown_until
      }
      |> Ecto.put_meta(state: :loaded)

    recorded = %Recorded{published: published, cooldown: cooldown}
    {configuration, settings, recorded}
  end
end

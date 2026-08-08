defmodule ClusterMurmur.Personas.ResponderCooldownRecorderTest do
  use ExUnit.Case, async: true

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
  @spoken_at ~U[2026-08-07 02:00:06.000000Z]
  @cooldown_until ~U[2026-08-07 02:01:06.000000Z]

  defmodule FakeStore do
    def record_spoken(persona_id, spoken_at, cooldown_until) do
      Process.put({__MODULE__, :input}, {persona_id, spoken_at, cooldown_until})

      {:ok,
       %PersonaCooldownRecord{
         persona_id: persona_id,
         last_spoken_at: spoken_at,
         cooldown_until: cooldown_until
       }
       |> Ecto.put_meta(state: :loaded)}
    end
  end

  defmodule ConflictingStore do
    def record_spoken(_persona_id, _spoken_at, _cooldown_until),
      do: {:error, :persona_cooldown_conflict}
  end

  defmodule WrongStore do
    def record_spoken(persona_id, spoken_at, cooldown_until) do
      {:ok,
       %PersonaCooldownRecord{
         persona_id: persona_id,
         last_spoken_at: spoken_at,
         cooldown_until: DateTime.add(cooldown_until, 1, :second)
       }
       |> Ecto.put_meta(state: :loaded)}
    end
  end

  defmodule RaisingStore do
    def record_spoken(_persona_id, _spoken_at, _cooldown_until),
      do: raise("private storage diagnostic")
  end

  setup do
    Process.delete({FakeStore, :input})
    :ok
  end

  test "records the proven speaker at publication completion using current policy" do
    {configuration, settings, published} = scenario()

    assert {:ok, %Recorded{} = recorded} =
             ResponderCooldownRecorder.record(
               published,
               configuration,
               cooldowns(published),
               settings,
               FakeStore
             )

    assert Process.get({FakeStore, :input}) ==
             {published.message.persona_id, @spoken_at, @cooldown_until}

    assert recorded.published === published
    assert recorded.cooldown.persona_id == published.message.persona_id
    assert recorded.cooldown.last_spoken_at == @spoken_at
    assert recorded.cooldown.cooldown_until == @cooldown_until

    assert ResponderCooldownRecorder.validate(
             recorded,
             configuration,
             cooldowns(published),
             settings
           ) == :ok

    inspected = inspect(recorded)
    refute inspected =~ published.message.content
    refute inspected =~ "fake-token"
  end

  test "does not record failed or ambiguous publication outcomes" do
    {configuration, settings, published} = scenario()

    for {status, error_class} <- [{:failed, :timeout}, {:ambiguous, :interrupted}] do
      attempt = %{published.attempt | status: status, error_class: error_class}

      candidate = %Outcome{
        published
        | status: status,
          error_class: error_class,
          attempt: attempt,
          message: nil
      }

      assert ResponderPublicationExecutor.validate(
               candidate,
               configuration,
               cooldowns(published),
               settings
             ) == :ok

      assert ResponderCooldownRecorder.record(
               candidate,
               configuration,
               cooldowns(published),
               settings,
               FakeStore
             ) == {:error, :invalid_responder_cooldown}
    end

    assert Process.get({FakeStore, :input}) == nil
  end

  test "rejects forged publication capabilities and changed current policy" do
    {configuration, settings, published} = scenario()

    changed =
      put_in(
        configuration.personas.personas["responder"].behavior["cooldown_ms"],
        30_000
      )

    for {candidate, current_configuration} <- [
          {Map.put(published, :private, true), configuration},
          {%{published | status: :failed}, configuration},
          {published, changed}
        ] do
      assert ResponderCooldownRecorder.record(
               candidate,
               current_configuration,
               cooldowns(published),
               settings,
               FakeStore
             ) == {:error, :invalid_responder_cooldown}
    end

    assert ResponderCooldownRecorder.record(
             published,
             configuration,
             %{},
             settings,
             FakeStore
           ) == {:error, :invalid_responder_cooldown}

    assert Process.get({FakeStore, :input}) == nil
  end

  test "preserves conflicts and rejects mismatched store records" do
    {configuration, settings, published} = scenario()

    assert ResponderCooldownRecorder.record(
             published,
             configuration,
             cooldowns(published),
             settings,
             ConflictingStore
           ) == {:error, :persona_cooldown_conflict}

    assert ResponderCooldownRecorder.record(
             published,
             configuration,
             cooldowns(published),
             settings,
             WrongStore
           ) == {:error, :invalid_persona_cooldown_record}
  end

  test "contains store failures and rejects forged recorded capabilities" do
    {configuration, settings, published} = scenario()

    result =
      ResponderCooldownRecorder.record(
        published,
        configuration,
        cooldowns(published),
        settings,
        RaisingStore
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"

    assert {:ok, recorded} =
             ResponderCooldownRecorder.record(
               published,
               configuration,
               cooldowns(published),
               settings,
               FakeStore
             )

    for forged <- [
          nil,
          Map.put(recorded, :private, true),
          %{recorded | cooldown: %{recorded.cooldown | persona_id: "other"}},
          %{
            recorded
            | cooldown: %{
                recorded.cooldown
                | cooldown_until: DateTime.add(@cooldown_until, 1, :second)
              }
          }
        ] do
      assert ResponderCooldownRecorder.validate(
               forged,
               configuration,
               cooldowns(published),
               settings
             ) == {:error, :invalid_responder_cooldown}
    end
  end

  defp scenario do
    configuration = RuntimeFixture.responder_configuration()
    input = RuntimeFixture.responder_input(configuration)
    settings = input.webhook_settings
    delivery = RuntimeFixture.responder_delivery(configuration)

    {:ok, plan} =
      ResponderPublicationPlanner.plan(
        delivery,
        configuration,
        input.current_cooldowns,
        settings
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

    started = %ResponderPublicationStarter.Started{plan: plan, attempt: started_attempt}

    assert ResponderPublicationStarter.validate(
             started,
             configuration,
             input.current_cooldowns,
             settings
           ) == :ok

    attempt = %{
      started_attempt
      | status: :succeeded,
        completed_at: @spoken_at,
        error_class: nil
    }

    message = %{delivery.message | discord_message_id: "12345"}

    published = %Outcome{
      started: started,
      attempt: attempt,
      message: message,
      status: :succeeded,
      error_class: nil
    }

    assert ResponderPublicationExecutor.validate(
             published,
             configuration,
             input.current_cooldowns,
             settings
           ) == :ok

    {configuration, settings, published}
  end

  defp cooldowns(published), do: published.started.plan.delivery.plan.input.current_cooldowns
end

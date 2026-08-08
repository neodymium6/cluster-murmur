defmodule ClusterMurmur.Discord.ResponderPublicationStarterTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.ResponderPublicationStarter
  alias ClusterMurmur.Discord.ResponderPublicationStarter.Started
  alias ClusterMurmur.Persistence.PublicationAttemptRecord
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @started_at ~U[2026-08-07 02:00:05.000000Z]

  defmodule FakeStore do
    def start(plan, record, persona, settings, started_at) do
      Process.put({__MODULE__, :input}, {plan, record, persona, settings, started_at})

      {:ok,
       %PublicationAttemptRecord{
         message_id: record.id,
         status: :started,
         started_at: started_at,
         completed_at: nil,
         error_class: nil
       }
       |> Ecto.put_meta(state: :loaded)}
    end
  end

  defmodule ConflictingStore do
    def start(_plan, _record, _persona, _settings, _started_at),
      do: {:error, :publication_attempt_conflict}
  end

  defmodule MalformedStore do
    def start(_plan, _record, _persona, _settings, _started_at),
      do: {:ok, %PublicationAttemptRecord{}}
  end

  defmodule WrongTimeStore do
    def start(_plan, record, _persona, _settings, started_at) do
      {:ok,
       %PublicationAttemptRecord{
         message_id: record.id,
         status: :started,
         started_at: DateTime.add(started_at, 1, :second),
         completed_at: nil,
         error_class: nil
       }
       |> Ecto.put_meta(state: :loaded)}
    end
  end

  defmodule RaisingStore do
    def start(_plan, _record, _persona, _settings, _started_at),
      do: raise("private storage diagnostic")
  end

  setup do
    Process.delete({FakeStore, :input})
    :ok
  end

  test "starts one exact redacted durable responder publication attempt" do
    {configuration, cooldowns, settings, plan} = scenario()

    assert {:ok, %Started{} = started} =
             ResponderPublicationStarter.start(
               plan,
               configuration,
               cooldowns,
               settings,
               @started_at,
               FakeStore
             )

    assert Process.get({FakeStore, :input}) ===
             {
               plan.publication,
               plan.delivery.message,
               plan.publication.persona,
               settings,
               @started_at
             }

    assert started.plan === plan
    assert started.attempt.message_id == plan.delivery.message.id
    assert started.attempt.status == :started
    assert started.attempt.started_at == @started_at

    assert ResponderPublicationStarter.validate(
             started,
             configuration,
             cooldowns,
             settings
           ) == :ok

    inspected = inspect(started)
    refute inspected =~ plan.delivery.message.content
    refute inspected =~ "fake-token"
  end

  test "rejects forged plans and invalid start instants before store access" do
    {configuration, cooldowns, settings, plan} = scenario()

    for {candidate, started_at} <- [
          {nil, @started_at},
          {Map.put(plan, :private, true), @started_at},
          {plan, ~U[2026-08-07 02:00:03.000000Z]}
        ] do
      assert {:error, _reason} =
               ResponderPublicationStarter.start(
                 candidate,
                 configuration,
                 cooldowns,
                 settings,
                 started_at,
                 FakeStore
               )
    end

    assert Process.get({FakeStore, :input}) == nil
  end

  test "preserves stable conflicts and contains malformed store outcomes" do
    {configuration, cooldowns, settings, plan} = scenario()

    assert start(plan, configuration, cooldowns, settings, ConflictingStore) ==
             {:error, :publication_attempt_conflict}

    assert start(plan, configuration, cooldowns, settings, MalformedStore) ==
             {:error, :invalid_publication_attempt_record}

    assert start(plan, configuration, cooldowns, settings, WrongTimeStore) ==
             {:error, :invalid_publication_attempt_record}

    result = start(plan, configuration, cooldowns, settings, RaisingStore)
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  test "revalidates exact started attempt and current input correlation" do
    {configuration, cooldowns, settings, plan} = scenario()

    assert {:ok, started} =
             start(plan, configuration, cooldowns, settings, FakeStore)

    for forged <- [
          nil,
          Map.put(started, :private, true),
          %{started | attempt: %{started.attempt | message_id: 3}},
          %{started | attempt: %{started.attempt | status: :dispatching}},
          %{started | attempt: %{started.attempt | started_at: ~U[2026-08-07 02:00:03.000000Z]}},
          %{
            started
            | plan: %{
                plan
                | delivery: %{
                    plan.delivery
                    | message: %{plan.delivery.message | content: "Altered response."}
                  }
              }
          }
        ] do
      assert ResponderPublicationStarter.validate(
               forged,
               configuration,
               cooldowns,
               settings
             ) == {:error, :invalid_responder_publication}
    end
  end

  defp start(plan, configuration, cooldowns, settings, store) do
    ResponderPublicationStarter.start(
      plan,
      configuration,
      cooldowns,
      settings,
      @started_at,
      store
    )
  end

  defp scenario do
    configuration = RuntimeFixture.responder_configuration()
    input = RuntimeFixture.responder_input(configuration)
    plan = RuntimeFixture.responder_publication_plan(configuration)
    {configuration, input.current_cooldowns, input.webhook_settings, plan}
  end
end

defmodule ClusterMurmur.Discord.StarterPublicationStarterTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{StarterPublicationPlanner, StarterPublicationStarter}
  alias ClusterMurmur.Discord.StarterPublicationStarter.Started
  alias ClusterMurmur.Persistence.PublicationAttemptRecord
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @started_at ~U[2026-08-07 02:00:02.000000Z]

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

  test "starts one exact redacted durable publication attempt" do
    {configuration, settings, plan} = scenario()

    assert {:ok, %Started{} = started} =
             StarterPublicationStarter.start(
               plan,
               configuration,
               %{},
               settings,
               @started_at,
               FakeStore
             )

    assert Process.get({FakeStore, :input}) ===
             {
               plan.publication,
               plan.persisted.message,
               plan.publication.persona,
               settings,
               @started_at
             }

    assert started.plan === plan
    assert started.attempt.message_id == plan.persisted.message.id
    assert started.attempt.status == :started
    assert started.attempt.started_at == @started_at
    assert StarterPublicationStarter.validate(started, configuration, %{}, settings) == :ok

    inspected = inspect(started)
    refute inspected =~ plan.persisted.message.content
    refute inspected =~ "fake-token"
  end

  test "rejects forged plans and invalid start instants before store access" do
    {configuration, settings, plan} = scenario()

    for {candidate, started_at} <- [
          {nil, @started_at},
          {Map.put(plan, :private, true), @started_at},
          {plan, ~U[2026-08-07 02:00:00.000000Z]}
        ] do
      assert {:error, _reason} =
               StarterPublicationStarter.start(
                 candidate,
                 configuration,
                 %{},
                 settings,
                 started_at,
                 FakeStore
               )
    end

    assert Process.get({FakeStore, :input}) == nil
  end

  test "preserves stable conflicts and contains malformed store outcomes" do
    {configuration, settings, plan} = scenario()

    assert StarterPublicationStarter.start(
             plan,
             configuration,
             %{},
             settings,
             @started_at,
             ConflictingStore
           ) == {:error, :publication_attempt_conflict}

    assert StarterPublicationStarter.start(
             plan,
             configuration,
             %{},
             settings,
             @started_at,
             MalformedStore
           ) == {:error, :invalid_publication_attempt_record}

    assert StarterPublicationStarter.start(
             plan,
             configuration,
             %{},
             settings,
             @started_at,
             WrongTimeStore
           ) == {:error, :invalid_publication_attempt_record}

    result =
      StarterPublicationStarter.start(
        plan,
        configuration,
        %{},
        settings,
        @started_at,
        RaisingStore
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  test "revalidates exact started-attempt and current input correlation" do
    {configuration, settings, plan} = scenario()

    assert {:ok, started} =
             StarterPublicationStarter.start(
               plan,
               configuration,
               %{},
               settings,
               @started_at,
               FakeStore
             )

    for forged <- [
          nil,
          Map.put(started, :private, true),
          %{started | attempt: %{started.attempt | message_id: 2}},
          %{started | attempt: %{started.attempt | status: :dispatching}},
          %{started | attempt: %{started.attempt | started_at: ~U[2026-08-07 02:00:00.000000Z]}},
          %{
            started
            | plan: %{
                plan
                | persisted: %{
                    plan.persisted
                    | message: %{plan.persisted.message | content: "Other"}
                  }
              }
          }
        ] do
      assert StarterPublicationStarter.validate(forged, configuration, %{}, settings) ==
               {:error, :invalid_starter_publication}
    end
  end

  defp scenario do
    configuration = RuntimeFixture.configuration()
    settings = RuntimeFixture.webhook_settings()
    persisted = RuntimeFixture.persisted(configuration)
    {:ok, plan} = StarterPublicationPlanner.plan(persisted, configuration, %{}, settings)
    {configuration, settings, plan}
  end
end

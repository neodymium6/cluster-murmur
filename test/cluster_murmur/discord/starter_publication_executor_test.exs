defmodule ClusterMurmur.Discord.StarterPublicationExecutorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{
    StarterPublicationExecutor,
    StarterPublicationPlanner,
    StarterPublicationStarter
  }

  alias ClusterMurmur.Discord.StarterPublicationExecutor.Outcome
  alias ClusterMurmur.Persistence.PublicationAttemptRecord
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @started_at ~U[2026-08-07 02:00:02.000000Z]
  @completed_at ~U[2026-08-07 02:00:03Z]
  @normalized_completed_at ~U[2026-08-07 02:00:03.000000Z]

  defmodule StartStore do
    def start(_plan, record, _persona, _settings, started_at) do
      {:ok,
       loaded_attempt(%{
         message_id: record.id,
         status: :started,
         started_at: started_at,
         completed_at: nil,
         error_class: nil
       })}
    end

    defp loaded_attempt(fields) do
      struct!(PublicationAttemptRecord, fields) |> Ecto.put_meta(state: :loaded)
    end
  end

  defmodule FakePublisher do
    def publish(attempt, plan, message, persona, settings, transport) do
      Process.put({__MODULE__, :input}, {attempt, plan, message, persona, settings, transport})
      dispatching = %{attempt | status: :dispatching}

      case Process.get({__MODULE__, :outcome}, :success) do
        :success -> {:ok, "12345", dispatching}
        {:failed, error_class} -> {:failed, error_class, dispatching}
        :ambiguous -> {:ambiguous, :interrupted, dispatching}
        :malformed -> {:ok, "12345", %{dispatching | message_id: message.id + 1}}
        :raise -> raise "private publisher diagnostic"
      end
    end
  end

  defmodule FakeStore do
    def succeed(dispatching, message, discord_message_id, completed_at) do
      Process.put(
        {__MODULE__, :input},
        {:succeed, dispatching, message, discord_message_id, completed_at}
      )

      attempt = terminal(dispatching, :succeeded, nil, completed_at)
      published = %{message | discord_message_id: discord_message_id}
      {:ok, {attempt, published}}
    end

    def fail(dispatching, error_class, completed_at) do
      Process.put({__MODULE__, :input}, {:fail, dispatching, error_class, completed_at})
      {:ok, terminal(dispatching, :failed, error_class, completed_at)}
    end

    def mark_ambiguous(dispatching, completed_at) do
      Process.put({__MODULE__, :input}, {:mark_ambiguous, dispatching, completed_at})
      {:ok, terminal(dispatching, :ambiguous, :interrupted, completed_at)}
    end

    defp terminal(attempt, status, error_class, completed_at) do
      %{attempt | status: status, error_class: error_class, completed_at: completed_at}
    end
  end

  defmodule WrongResultStore do
    def succeed(dispatching, message, discord_message_id, completed_at) do
      {:ok,
       {
         %{
           dispatching
           | status: :succeeded,
             completed_at: DateTime.add(completed_at, 1, :second)
         },
         %{message | discord_message_id: discord_message_id}
       }}
    end

    def fail(_dispatching, _error_class, _completed_at), do: raise("unused")
    def mark_ambiguous(_dispatching, _completed_at), do: raise("unused")
  end

  defmodule RaisingStore do
    def succeed(_dispatching, _message, _discord_message_id, _completed_at),
      do: raise("private storage diagnostic")

    def fail(_dispatching, _error_class, _completed_at), do: raise("private storage diagnostic")
    def mark_ambiguous(_dispatching, _completed_at), do: raise("private storage diagnostic")
  end

  setup do
    for key <- [
          {FakePublisher, :input},
          {FakePublisher, :outcome},
          {FakeStore, :input}
        ] do
      Process.delete(key)
    end

    :ok
  end

  test "publishes once and atomically records a correlated success" do
    {configuration, settings, started} = scenario()
    transport = fn _request -> raise "publisher owns transport invocation" end

    assert {:ok, %Outcome{} = outcome} =
             execute(started, configuration, settings, transport)

    assert outcome.status == :succeeded
    assert outcome.error_class == nil
    assert outcome.attempt.completed_at == @normalized_completed_at
    assert outcome.message.discord_message_id == "12345"
    assert StarterPublicationExecutor.validate(outcome, configuration, %{}, settings) == :ok

    assert {attempt, publication, message, persona, ^settings, ^transport} =
             Process.get({FakePublisher, :input})

    assert attempt === started.attempt
    assert publication === started.plan.publication
    assert message === started.plan.persisted.message
    assert persona === started.plan.publication.persona

    assert {:succeed, dispatching, ^message, "12345", @normalized_completed_at} =
             Process.get({FakeStore, :input})

    assert dispatching.status == :dispatching
    refute inspect(outcome) =~ message.content
    refute inspect(outcome) =~ "fake-token"
  end

  test "records known failure and ambiguous effect without retrying" do
    {configuration, settings, started} = scenario()
    transport = fn _request -> {:error, :outcome_unknown} end

    Process.put({FakePublisher, :outcome}, {:failed, :timeout})

    assert {:failed, :timeout, %Outcome{} = failed} =
             execute(started, configuration, settings, transport)

    assert failed.status == :failed
    assert failed.error_class == :timeout
    assert failed.message == nil

    assert {:fail, dispatching, :timeout, @normalized_completed_at} =
             Process.get({FakeStore, :input})

    assert dispatching.status == :dispatching
    assert StarterPublicationExecutor.validate(failed, configuration, %{}, settings) == :ok

    Process.put({FakePublisher, :outcome}, :ambiguous)

    assert {:ambiguous, :interrupted, %Outcome{} = ambiguous} =
             execute(started, configuration, settings, transport)

    assert ambiguous.status == :ambiguous
    assert ambiguous.error_class == :interrupted
    assert ambiguous.message == nil

    assert {:mark_ambiguous, ambiguous_dispatching, @normalized_completed_at} =
             Process.get({FakeStore, :input})

    assert ambiguous_dispatching.status == :dispatching
    assert StarterPublicationExecutor.validate(ambiguous, configuration, %{}, settings) == :ok
  end

  test "rejects forged capabilities and invalid completion time before publication" do
    {configuration, settings, started} = scenario()
    transport = fn _request -> {:error, :outcome_unknown} end

    for {candidate, completed_at} <- [
          {Map.put(started, :private, true), @completed_at},
          {%{started | attempt: %{started.attempt | message_id: 2}}, @completed_at},
          {started, ~U[2026-08-07 02:00:01.000000Z]}
        ] do
      assert {:error, _reason} =
               execute(candidate, configuration, settings, transport, completed_at)
    end

    assert Process.get({FakePublisher, :input}) == nil
    assert Process.get({FakeStore, :input}) == nil
  end

  test "rejects malformed publisher and store outcomes" do
    {configuration, settings, started} = scenario()
    transport = fn _request -> {:error, :outcome_unknown} end

    Process.put({FakePublisher, :outcome}, :malformed)

    assert execute(started, configuration, settings, transport) ==
             {:error, :invalid_publication_attempt_record}

    assert Process.get({FakeStore, :input}) == nil

    Process.put({FakePublisher, :outcome}, :success)

    assert StarterPublicationExecutor.execute(
             started,
             configuration,
             %{},
             settings,
             @completed_at,
             transport,
             FakePublisher,
             WrongResultStore
           ) == {:error, :invalid_publication_outcome}
  end

  test "contains adapter failures without exposing diagnostics" do
    {configuration, settings, started} = scenario()
    transport = fn _request -> {:error, :outcome_unknown} end

    Process.put({FakePublisher, :outcome}, :raise)
    result = execute(started, configuration, settings, transport)
    assert result == {:error, :publisher_unavailable}
    refute inspect(result) =~ "private"

    Process.put({FakePublisher, :outcome}, :success)

    result =
      StarterPublicationExecutor.execute(
        started,
        configuration,
        %{},
        settings,
        @completed_at,
        transport,
        FakePublisher,
        RaisingStore
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  test "rejects forged terminal capabilities" do
    {configuration, settings, started} = scenario()
    transport = fn _request -> {:error, :outcome_unknown} end
    assert {:ok, outcome} = execute(started, configuration, settings, transport)

    for forged <- [
          nil,
          Map.put(outcome, :private, true),
          %{outcome | status: :failed},
          %{outcome | attempt: %{outcome.attempt | message_id: 2}},
          %{outcome | message: %{outcome.message | content: "Changed"}},
          %{outcome | message: nil}
        ] do
      assert StarterPublicationExecutor.validate(forged, configuration, %{}, settings) ==
               {:error, :invalid_publication_outcome}
    end
  end

  defp execute(started, configuration, settings, transport, completed_at \\ @completed_at) do
    StarterPublicationExecutor.execute(
      started,
      configuration,
      %{},
      settings,
      completed_at,
      transport,
      FakePublisher,
      FakeStore
    )
  end

  defp scenario do
    configuration = RuntimeFixture.configuration()
    settings = RuntimeFixture.webhook_settings()
    persisted = RuntimeFixture.persisted(configuration)
    {:ok, plan} = StarterPublicationPlanner.plan(persisted, configuration, %{}, settings)

    {:ok, started} =
      StarterPublicationStarter.start(
        plan,
        configuration,
        %{},
        settings,
        @started_at,
        StartStore
      )

    {configuration, settings, started}
  end
end

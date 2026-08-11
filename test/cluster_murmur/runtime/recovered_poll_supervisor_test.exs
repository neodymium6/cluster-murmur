defmodule ClusterMurmur.Runtime.RecoveredPollSupervisorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.Observers.Client
  alias ClusterMurmur.Persistence.PublicationAttemptRecord

  alias ClusterMurmur.Runtime.{
    PollScheduler,
    PollStarterCycle,
    RecoveredPollSupervisor
  }

  alias ClusterMurmur.Runtime.PollScheduler.Options, as: SchedulerOptions
  alias ClusterMurmur.Runtime.RecoveredPollSupervisor.Options
  alias ClusterMurmur.Runtime.Recovery.Stores
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, SharedInput}

  @started_at ~U[2026-08-08 12:00:00.000000Z]

  defmodule FixedClock do
    @behaviour ClusterMurmur.Runtime.Clock

    def utc_now do
      Process.put(
        {ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :clock_count},
        clock_count() + 1
      )

      ~U[2026-08-08 12:00:00.000000Z]
    end

    defp clock_count,
      do: Process.get({ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :clock_count}, 0)
  end

  defmodule Observer do
    def list_targets(_context), do: {:ok, []}
    def observe_target(_context, _target), do: :unused
  end

  defmodule OtherClock do
    @behaviour ClusterMurmur.Runtime.Clock
    def utc_now, do: ~U[2026-08-08 12:00:00.000000Z]
  end

  defmodule IngestionStore do
    def ingest(_observation, _policy), do: :unused
  end

  defmodule AdapterStub do
    def consume(_plan), do: :unused
    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused
    def fetch(_persona_id), do: {:ok, nil}
    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def complete(_conversation_id, _completed_at), do: :unused
    def wait(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused
  end

  defmodule Executions do
    def list_started_before(cutoff) do
      trace({:executions, cutoff})
      Process.get({ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :executions}, {:ok, []})
    end

    def fail_abandoned(execution, _cutoff) do
      trace({:fail_execution, execution.trigger_id})
      {:ok, :terminal}
    end

    defp trace(entry),
      do:
        Process.put(
          {ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :trace},
          trace() ++ [entry]
        )

    defp trace,
      do: Process.get({ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :trace}, [])
  end

  defmodule Conversations do
    def list_active_before(cutoff) do
      trace({:conversations, cutoff})
      {:ok, []}
    end

    def fail(_conversation, _recovered_at), do: :unused

    defp trace(entry),
      do:
        Process.put(
          {ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :trace},
          trace() ++ [entry]
        )

    defp trace,
      do: Process.get({ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :trace}, [])
  end

  defmodule Publications do
    def list_open_before(cutoff) do
      trace({:publications, cutoff})

      Process.get(
        {ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :publications},
        {:ok, []}
      )
    end

    def mark_ambiguous(_publication, recovered_at) do
      trace({:mark_ambiguous, recovered_at})
      {:error, :conflict}
    end

    defp trace(entry),
      do:
        Process.put(
          {ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :trace},
          trace() ++ [entry]
        )

    defp trace,
      do: Process.get({ClusterMurmur.Runtime.RecoveredPollSupervisorTest, :trace}, [])
  end

  defmodule RestartStores do
    @sink ClusterMurmur.Runtime.RecoveredPollSupervisorTest.RecoverySink

    def list_started_before(_cutoff), do: loaded(:executions)
    def list_active_before(_cutoff), do: loaded(:conversations)
    def list_open_before(_cutoff), do: loaded(:publications)
    def fail_abandoned(_execution, _cutoff), do: :unused
    def fail(_conversation, _recovered_at), do: :unused
    def mark_ambiguous(_publication, _recovered_at), do: :unused

    defp loaded(kind) do
      send(Process.whereis(@sink), {:recovery_loaded, kind})
      {:ok, []}
    end
  end

  setup do
    Process.put({__MODULE__, :clock_count}, 0)
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :executions}, {:ok, []})
    Process.put({__MODULE__, :publications}, {:ok, []})
    :ok
  end

  test "uses one startup instant for complete recovery before starting the scheduler" do
    assert {:ok, supervisor} = RecoveredPollSupervisor.start_link(options(), stores())
    Process.unlink(supervisor)
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)

    assert Process.get({__MODULE__, :clock_count}) == 1

    assert Process.get({__MODULE__, :trace}) == [
             {:executions, @started_at},
             {:conversations, @started_at},
             {:publications, @started_at}
           ]

    assert [{PollScheduler, scheduler, :worker, [PollScheduler]}] =
             Supervisor.which_children(supervisor)

    assert Process.alive?(scheduler)
    assert inspect(options()) == "#ClusterMurmur.Runtime.RecoveredPollSupervisor.Options<...>"
  end

  test "reruns recovery through the parent before replacing a crashed scheduler" do
    Process.register(self(), ClusterMurmur.Runtime.RecoveredPollSupervisorTest.RecoverySink)

    child = %{
      id: :recovered_poll,
      start: {RecoveredPollSupervisor, :start_link, [options(), restart_stores()]},
      restart: :permanent,
      type: :supervisor
    }

    assert {:ok, parent} = Supervisor.start_link([child], strategy: :one_for_one)
    Process.unlink(parent)
    on_exit(fn -> if Process.alive?(parent), do: Supervisor.stop(parent) end)

    assert_receive {:recovery_loaded, :executions}
    assert_receive {:recovery_loaded, :conversations}
    assert_receive {:recovery_loaded, :publications}

    assert [{:recovered_poll, recovered, :supervisor, [RecoveredPollSupervisor]}] =
             Supervisor.which_children(parent)

    assert [{PollScheduler, scheduler, :worker, [PollScheduler]}] =
             Supervisor.which_children(recovered)

    Process.exit(scheduler, :kill)

    assert_receive {:recovery_loaded, :executions}
    assert_receive {:recovery_loaded, :conversations}
    assert_receive {:recovery_loaded, :publications}

    assert [{:recovered_poll, replacement, :supervisor, [RecoveredPollSupervisor]}] =
             Supervisor.which_children(parent)

    refute replacement == recovered

    assert [{PollScheduler, replacement_scheduler, :worker, [PollScheduler]}] =
             Supervisor.which_children(replacement)

    refute replacement_scheduler == scheduler
  end

  test "requires another startup pass after a saturated bounded recovery page" do
    Process.put({__MODULE__, :executions}, {:ok, List.duplicate(execution(), 100)})

    assert RecoveredPollSupervisor.start_link(options(), stores()) ==
             {:error, :invalid_recovered_poll_supervisor}

    assert Process.get({__MODULE__, :clock_count}) == 1
    assert length(Process.get({__MODULE__, :trace})) == 103
  end

  test "does not start the scheduler when one recovery mutation remains incomplete" do
    publication =
      %PublicationAttemptRecord{
        message_id: 1,
        status: :started,
        started_at: @started_at,
        completed_at: nil,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    Process.put({__MODULE__, :publications}, {:ok, [publication]})

    assert RecoveredPollSupervisor.start_link(options(), stores()) ==
             {:error, :invalid_recovered_poll_supervisor}

    assert Process.get({__MODULE__, :trace}) == [
             {:executions, @started_at},
             {:conversations, @started_at},
             {:publications, @started_at},
             {:mark_ambiguous, @started_at}
           ]
  end

  test "rejects invalid runtime dependencies before reading the clock or recovery stores" do
    valid = options()
    valid_stores = stores()

    for {invalid, invalid_stores} <- [
          {%{valid | scheduler: %{valid.scheduler | interval_ms: 0}}, valid_stores},
          {%{valid | clock: String}, valid_stores},
          {%{valid | clock: OtherClock}, valid_stores},
          {Map.put(valid, :private, true), valid_stores},
          {valid, %{valid_stores | executions: String}},
          {valid, Map.put(valid_stores, :private, true)}
        ] do
      assert RecoveredPollSupervisor.start_link(invalid, invalid_stores) ==
               {:error, :invalid_recovered_poll_supervisor}
    end

    assert Process.get({__MODULE__, :clock_count}) == 0
    assert Process.get({__MODULE__, :trace}) == []
  end

  defp options do
    configuration =
      RuntimeFixture.configuration()
      |> Map.put(
        :state_tracking,
        %StateTracking{failures_required: 2, successes_required: 2}
      )

    {:ok, observer_client} = Client.new(Observer, :unused)

    %Options{
      clock: FixedClock,
      scheduler: %SchedulerOptions{
        observer_client: observer_client,
        configuration: configuration,
        cycle_context: cycle_context(configuration),
        ingestion_store: IngestionStore,
        clock: FixedClock,
        interval_ms: 60_000,
        initial_delay_ms: 60_000
      }
    }
  end

  defp cycle_context(configuration) do
    %PollStarterCycle.Context{
      shared_input: %SharedInput{
        configuration: configuration,
        cooldowns: %{},
        provider_settings: RuntimeFixture.provider_settings(),
        webhook_settings: RuntimeFixture.webhook_settings(),
        generation_transport: fn _request -> :unused end,
        publication_transport: fn _request -> :unused end
      },
      adapters: adapters()
    }
  end

  defp adapters do
    %Adapters{
      conversation_action_store: AdapterStub,
      provider: AdapterStub,
      message_store: AdapterStub,
      publication_start_store: AdapterStub,
      publisher: AdapterStub,
      publication_terminal_store: AdapterStub,
      cooldown_store: AdapterStub,
      conversation_store: AdapterStub,
      starter_random: AdapterStub,
      reply_random: AdapterStub
    }
  end

  defp stores do
    %Stores{executions: Executions, conversations: Conversations, publications: Publications}
  end

  defp restart_stores do
    %Stores{executions: RestartStores, conversations: RestartStores, publications: RestartStores}
  end

  defp execution do
    %ClusterMurmur.Persistence.TriggerExecution{
      trigger_id: "trigger-a",
      event_id: "event-a",
      status: :started,
      executed_at: @started_at,
      cooldown_until: ~U[2026-08-08 13:00:00.000000Z],
      error_class: nil
    }
    |> Ecto.put_meta(state: :loaded)
  end
end

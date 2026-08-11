defmodule ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{StateTracking, Triggers}
  alias ClusterMurmur.Observers.Client
  alias ClusterMurmur.Persistence.PublicationAttemptRecord

  alias ClusterMurmur.Runtime.{
    EventDispatchCycle,
    EventDispatchScheduler,
    EventRetentionCycle,
    EventRetentionScheduler,
    PollScheduler,
    PollStarterCycle,
    RecurringScheduleCycle,
    RecurringScheduleInitializer,
    RecurringScheduleScheduler,
    RecoveredRuntimeSupervisor,
    StochasticCycle,
    StochasticScheduleInitializer,
    StochasticScheduler
  }

  alias ClusterMurmur.Runtime.EventDispatchCycle.{Adapters, Context}
  alias ClusterMurmur.Runtime.EventDispatchScheduler.Options, as: DispatchOptions
  alias ClusterMurmur.Runtime.EventRetentionScheduler.Options, as: RetentionOptions
  alias ClusterMurmur.Runtime.PollScheduler.Options, as: PollOptions
  alias ClusterMurmur.Runtime.RecurringScheduleScheduler.Options, as: RecurringOptions
  alias ClusterMurmur.Runtime.RecoveredRuntimeSupervisor.Options
  alias ClusterMurmur.Runtime.Recovery.Stores
  alias ClusterMurmur.Runtime.StochasticScheduler.Options, as: StochasticOptions
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.SharedInput
  alias ClusterMurmur.Triggers.{EmittedEvent, ScheduleTrigger, StochasticTrigger}

  @started_at ~U[2026-08-08 18:30:00.000000Z]

  defmodule FixedClock do
    @behaviour ClusterMurmur.Runtime.Clock

    def utc_now do
      key = {ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, :clock_count}
      Process.put(key, Process.get(key, 0) + 1)
      ~U[2026-08-08 18:30:00.000000Z]
    end
  end

  defmodule OtherClock do
    @behaviour ClusterMurmur.Runtime.Clock
    def utc_now, do: ~U[2026-08-08 18:30:00.000000Z]
  end

  defmodule Observer do
    def list_targets(_context), do: {:ok, []}
    def observe_target(_context, _target), do: :unused
  end

  defmodule AdapterStub do
    def list_available(_now), do: {:ok, []}
    def claim(_candidate, _now), do: :unused
    def complete(_value, _completed_at), do: :unused
    def fetch(_event_id), do: :unused
    def authorize(_trigger, _event, _now, _event_policy), do: :unused
    def ingest(_observation, _policy), do: :unused

    def consume(_plan), do: :unused
    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused
    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def wait(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused
  end

  defmodule Executions do
    def list_started_before(cutoff) do
      trace({:executions, cutoff})
      Process.get({ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, :executions}, {:ok, []})
    end

    def fail_abandoned(execution, _cutoff) do
      trace({:fail_execution, execution.trigger_id})
      {:ok, :terminal}
    end

    defp trace(entry) do
      key = {ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, :trace}
      Process.put(key, Process.get(key, []) ++ [entry])
    end
  end

  defmodule Conversations do
    def list_active_before(cutoff) do
      trace({:conversations, cutoff})
      {:ok, []}
    end

    def fail(_conversation, _recovered_at), do: :unused

    defp trace(entry) do
      key = {ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, :trace}
      Process.put(key, Process.get(key, []) ++ [entry])
    end
  end

  defmodule Publications do
    def list_open_before(cutoff) do
      trace({:publications, cutoff})

      Process.get(
        {ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, :publications},
        {:ok, []}
      )
    end

    def mark_ambiguous(_publication, recovered_at) do
      trace({:mark_ambiguous, recovered_at})
      {:error, :conflict}
    end

    defp trace(entry) do
      key = {ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, :trace}
      Process.put(key, Process.get(key, []) ++ [entry])
    end
  end

  defmodule RestartStores do
    @sink ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest.RecoverySink

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

  defmodule RecurringInitializer do
    alias ClusterMurmur.Runtime.RecurringScheduleInitializer.Result
    alias ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, as: Test

    def run(_configuration, initialized_at) do
      trace({:initialize_recurring, initialized_at})

      if sink = Process.whereis(Test.RecoverySink),
        do: send(sink, {:recurring_initialized, initialized_at})

      Process.get(
        {Test, :initialization},
        {:ok, %Result{schedule_count: 1}}
      )
    end

    defp trace(entry) do
      key = {Test, :trace}
      Process.put(key, Process.get(key, []) ++ [entry])
    end
  end

  defmodule StochasticInitializer do
    alias ClusterMurmur.Runtime.StochasticScheduleInitializer.Result
    alias ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest, as: Test

    def run(_configuration, initialized_at, random) do
      trace({:initialize_stochastic, initialized_at, random})

      if sink = Process.whereis(Test.RecoverySink),
        do: send(sink, {:stochastic_initialized, initialized_at})

      Process.get(
        {Test, :stochastic_initialization},
        {:ok, %Result{schedule_count: 1}}
      )
    end

    defp trace(entry) do
      key = {Test, :trace}
      Process.put(key, Process.get(key, []) ++ [entry])
    end
  end

  setup do
    Process.put({__MODULE__, :clock_count}, 0)
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :executions}, {:ok, []})
    Process.put({__MODULE__, :publications}, {:ok, []})

    Process.put(
      {__MODULE__, :initialization},
      {:ok, %RecurringScheduleInitializer.Result{schedule_count: 1}}
    )

    Process.put(
      {__MODULE__, :stochastic_initialization},
      {:ok, %StochasticScheduleInitializer.Result{schedule_count: 1}}
    )

    :ok
  end

  test "recovers and initializes once before starting all schedulers" do
    assert {:ok, supervisor} = RecoveredRuntimeSupervisor.start_link(options(), stores())
    Process.unlink(supervisor)
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)

    assert Process.get({__MODULE__, :clock_count}) == 1

    assert Process.get({__MODULE__, :trace}) == [
             {:executions, @started_at},
             {:conversations, @started_at},
             {:publications, @started_at},
             {:initialize_recurring, @started_at},
             {:initialize_stochastic, @started_at, AdapterStub}
           ]

    children = Supervisor.which_children(supervisor)
    assert child_pid(children, PollScheduler) |> Process.alive?()
    assert child_pid(children, EventDispatchScheduler) |> Process.alive?()
    assert child_pid(children, RecurringScheduleScheduler) |> Process.alive?()
    assert child_pid(children, StochasticScheduler) |> Process.alive?()
    assert child_pid(children, EventRetentionScheduler) |> Process.alive?()
    assert inspect(options()) == "#ClusterMurmur.Runtime.RecoveredRuntimeSupervisor.Options<...>"
  end

  test "stops all schedulers and reruns both gates before replacing any one" do
    Process.register(self(), ClusterMurmur.Runtime.RecoveredRuntimeSupervisorTest.RecoverySink)

    child = %{
      id: :recovered_runtime,
      start: {RecoveredRuntimeSupervisor, :start_link, [options(), restart_stores()]},
      restart: :permanent,
      type: :supervisor
    }

    assert {:ok, parent} = Supervisor.start_link([child], strategy: :one_for_one)
    Process.unlink(parent)
    on_exit(fn -> if Process.alive?(parent), do: Supervisor.stop(parent) end)

    assert_recovery_loaded()
    assert_receive {:recurring_initialized, @started_at}
    assert_receive {:stochastic_initialized, @started_at}
    recovered = supervisor_child(parent)
    original_children = Supervisor.which_children(recovered)
    poll = child_pid(original_children, PollScheduler)
    dispatch = child_pid(original_children, EventDispatchScheduler)
    recurring = child_pid(original_children, RecurringScheduleScheduler)
    stochastic = child_pid(original_children, StochasticScheduler)
    retention = child_pid(original_children, EventRetentionScheduler)

    Process.exit(dispatch, :kill)
    assert_recovery_loaded()
    assert_receive {:recurring_initialized, @started_at}
    assert_receive {:stochastic_initialized, @started_at}

    replacement = supervisor_child(parent)
    refute replacement == recovered
    replacement_children = Supervisor.which_children(replacement)
    replacement_poll = child_pid(replacement_children, PollScheduler)
    replacement_dispatch = child_pid(replacement_children, EventDispatchScheduler)
    replacement_recurring = child_pid(replacement_children, RecurringScheduleScheduler)
    replacement_stochastic = child_pid(replacement_children, StochasticScheduler)
    replacement_retention = child_pid(replacement_children, EventRetentionScheduler)

    refute replacement_poll == poll
    refute replacement_dispatch == dispatch
    refute replacement_recurring == recurring
    refute replacement_stochastic == stochastic
    refute replacement_retention == retention
    refute Process.alive?(poll)
    refute Process.alive?(recurring)
    refute Process.alive?(stochastic)
    refute Process.alive?(retention)
  end

  test "requires another startup pass after a saturated recovery page" do
    Process.put({__MODULE__, :executions}, {:ok, List.duplicate(execution(), 100)})

    assert RecoveredRuntimeSupervisor.start_link(options(), stores()) ==
             {:error, :invalid_recovered_runtime_supervisor}

    assert Process.get({__MODULE__, :clock_count}) == 1
    assert length(Process.get({__MODULE__, :trace})) == 103
  end

  test "starts no scheduler while one recovery mutation is incomplete" do
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

    assert RecoveredRuntimeSupervisor.start_link(options(), stores()) ==
             {:error, :invalid_recovered_runtime_supervisor}

    assert Process.get({__MODULE__, :trace}) == [
             {:executions, @started_at},
             {:conversations, @started_at},
             {:publications, @started_at},
             {:mark_ambiguous, @started_at}
           ]
  end

  test "starts no scheduler when recurring initialization is incomplete" do
    malformed =
      %RecurringScheduleInitializer.Result{schedule_count: 1}
      |> Map.put(:private, true)

    for response <- [
          {:error, :invalid_recurring_schedule_initialization},
          {:ok, malformed},
          {:ok, %RecurringScheduleInitializer.Result{schedule_count: 0}},
          {:ok, :not_an_initialization_result}
        ] do
      Process.put({__MODULE__, :trace}, [])
      Process.put({__MODULE__, :initialization}, response)

      assert RecoveredRuntimeSupervisor.start_link(options(), stores()) ==
               {:error, :invalid_recovered_runtime_supervisor}

      assert Process.get({__MODULE__, :trace}) == [
               {:executions, @started_at},
               {:conversations, @started_at},
               {:publications, @started_at},
               {:initialize_recurring, @started_at}
             ]
    end
  end

  test "starts no scheduler when stochastic initialization is incomplete" do
    malformed =
      %StochasticScheduleInitializer.Result{schedule_count: 1}
      |> Map.put(:private, true)

    for response <- [
          {:error, :invalid_stochastic_schedule_initialization},
          {:ok, malformed},
          {:ok, %StochasticScheduleInitializer.Result{schedule_count: 0}},
          {:ok, :not_an_initialization_result}
        ] do
      Process.put({__MODULE__, :trace}, [])
      Process.put({__MODULE__, :stochastic_initialization}, response)

      assert RecoveredRuntimeSupervisor.start_link(options(), stores()) ==
               {:error, :invalid_recovered_runtime_supervisor}

      assert Process.get({__MODULE__, :trace}) == [
               {:executions, @started_at},
               {:conversations, @started_at},
               {:publications, @started_at},
               {:initialize_recurring, @started_at},
               {:initialize_stochastic, @started_at, AdapterStub}
             ]
    end
  end

  test "rejects all scheduler and recovery adapters before reading the clock" do
    valid = options()
    valid_stores = stores()

    invalid_cases = [
      {%{valid | poll_scheduler: %{valid.poll_scheduler | interval_ms: 0}}, valid_stores},
      {%{
         valid
         | event_dispatch_scheduler: %{valid.event_dispatch_scheduler | interval_ms: 0}
       }, valid_stores},
      {%{
         valid
         | recurring_schedule_scheduler: %{
             valid.recurring_schedule_scheduler
             | interval_ms: 0
           }
       }, valid_stores},
      {%{valid | recurring_schedule_initializer: String}, valid_stores},
      {%{valid | stochastic_schedule_initializer: String}, valid_stores},
      {%{valid | stochastic_scheduler: %{valid.stochastic_scheduler | interval_ms: 0}},
       valid_stores},
      {%{valid | event_retention_scheduler: %{valid.event_retention_scheduler | interval_ms: 0}},
       valid_stores},
      {%{
         valid
         | recurring_schedule_scheduler: %{
             valid.recurring_schedule_scheduler
             | configuration: %{
                 valid.recurring_schedule_scheduler.configuration
                 | event_policy: %{
                     valid.recurring_schedule_scheduler.configuration.event_policy
                     | dedupe_window_ms: 60_000
                   }
               }
           }
       }, valid_stores},
      {%{valid | clock: String}, valid_stores},
      {%{valid | clock: OtherClock}, valid_stores},
      {%{valid | stochastic_scheduler: %{valid.stochastic_scheduler | clock: OtherClock}},
       valid_stores},
      {Map.put(valid, :private, true), valid_stores},
      {valid, %{valid_stores | executions: String}},
      {valid, Map.put(valid_stores, :private, true)}
    ]

    for {invalid_options, invalid_stores} <- invalid_cases do
      assert RecoveredRuntimeSupervisor.start_link(invalid_options, invalid_stores) ==
               {:error, :invalid_recovered_runtime_supervisor}
    end

    assert Process.get({__MODULE__, :clock_count}) == 0
    assert Process.get({__MODULE__, :trace}) == []
  end

  defp options do
    base_configuration =
      RuntimeFixture.configuration()
      |> Map.put(
        :state_tracking,
        %StateTracking{failures_required: 2, successes_required: 2}
      )

    schedule_trigger = recurring_trigger()
    stochastic_trigger = stochastic_trigger()

    configuration = %{
      base_configuration
      | triggers: %Triggers{
          triggers:
            base_configuration.triggers.triggers
            |> Map.put(schedule_trigger.id, schedule_trigger)
            |> Map.put(stochastic_trigger.id, stochastic_trigger)
        }
    }

    {:ok, observer_client} = Client.new(Observer, :unused)
    shared = shared_input(configuration)
    starter_adapters = starter_adapters()

    %Options{
      clock: FixedClock,
      poll_scheduler: %PollOptions{
        observer_client: observer_client,
        configuration: configuration,
        cycle_context: %PollStarterCycle.Context{
          shared_input: shared,
          adapters: starter_adapters
        },
        ingestion_store: AdapterStub,
        clock: FixedClock,
        interval_ms: 60_000,
        initial_delay_ms: 60_000
      },
      event_dispatch_scheduler: %DispatchOptions{
        configuration: configuration,
        cycle_context: %Context{shared_input: shared, adapters: starter_adapters},
        cycle_adapters: %Adapters{
          dispatches: AdapterStub,
          events: AdapterStub,
          authorizer: AdapterStub
        },
        cycle: EventDispatchCycle,
        clock: FixedClock,
        interval_ms: 60_000,
        initial_delay_ms: 60_000
      },
      recurring_schedule_scheduler: %RecurringOptions{
        configuration: configuration,
        cycle: RecurringScheduleCycle,
        clock: FixedClock,
        interval_ms: 60_000,
        initial_delay_ms: 60_000
      },
      stochastic_scheduler: %StochasticOptions{
        configuration: configuration,
        cycle: StochasticCycle,
        clock: FixedClock,
        random: AdapterStub,
        interval_ms: 60_000,
        initial_delay_ms: 60_000
      },
      event_retention_scheduler: %RetentionOptions{
        configuration: configuration,
        cycle: EventRetentionCycle,
        clock: FixedClock,
        interval_ms: 60_000,
        initial_delay_ms: 60_000
      },
      recurring_schedule_initializer: RecurringInitializer,
      stochastic_schedule_initializer: StochasticInitializer
    }
  end

  defp shared_input(configuration) do
    %SharedInput{
      configuration: configuration,
      cooldowns: %{},
      provider_settings: RuntimeFixture.provider_settings(),
      webhook_settings: RuntimeFixture.webhook_settings(),
      generation_transport: fn _request -> :unused end,
      publication_transport: fn _request -> :unused end
    }
  end

  defp recurring_trigger do
    {:ok, expression} = Crontab.CronExpression.Parser.parse("0 * * * *", false)

    %ScheduleTrigger{
      id: "hourly",
      cron: expression,
      timezone: "Etc/UTC",
      action: :emit_event,
      event: %EmittedEvent{
        type: "schedule.fired",
        group: "operations",
        subject: "hourly"
      }
    }
  end

  defp stochastic_trigger do
    %StochasticTrigger{
      id: "ambient",
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: nil,
      daily_limit: nil,
      action: :emit_event,
      event: %EmittedEvent{
        type: "stochastic.fired",
        group: "operations",
        subject: "ambient"
      }
    }
  end

  defp starter_adapters do
    %AuthorizedStarterPipeline.Adapters{
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
      cooldown_until: ~U[2026-08-08 19:30:00.000000Z],
      error_class: nil
    }
    |> Ecto.put_meta(state: :loaded)
  end

  defp supervisor_child(parent) do
    assert [{:recovered_runtime, supervisor, :supervisor, [RecoveredRuntimeSupervisor]}] =
             Supervisor.which_children(parent)

    supervisor
  end

  defp child_pid(children, module) do
    assert {^module, pid, :worker, [^module]} = Enum.find(children, &(elem(&1, 0) == module))
    pid
  end

  defp assert_recovery_loaded do
    assert_receive {:recovery_loaded, :executions}
    assert_receive {:recovery_loaded, :conversations}
    assert_receive {:recovery_loaded, :publications}
  end
end

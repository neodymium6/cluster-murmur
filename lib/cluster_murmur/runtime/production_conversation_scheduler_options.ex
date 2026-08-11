defmodule ClusterMurmur.Runtime.ProductionConversationSchedulerOptions do
  @moduledoc """
  Builds validated production options for poll and event conversation workers.

  Both first runs are delayed by their explicit recurring interval, avoiding an
  additional live timing default. Construction starts no process, schedules no
  timer, reads no clock or persistence, and invokes no external capability.
  """

  alias ClusterMurmur.Persistence.ObservationIngestionStore

  alias ClusterMurmur.Runtime.{
    EventDispatchCycle,
    EventDispatchScheduler,
    PollScheduler,
    ProductionConversationRuntime,
    SystemClock
  }

  alias ClusterMurmur.Startup
  alias ClusterMurmur.Startup.Prepared

  @derive {Inspect, only: []}
  @enforce_keys [:poll, :event_dispatch]
  defstruct [:poll, :event_dispatch]

  @type t :: %__MODULE__{
          poll: ClusterMurmur.Runtime.PollScheduler.Options.t(),
          event_dispatch: ClusterMurmur.Runtime.EventDispatchScheduler.Options.t()
        }

  @doc "Builds and validates both fixed conversation scheduler option values."
  @spec build(term()) ::
          {:ok, t()} | {:error, :invalid_production_conversation_scheduler_options}
  def build(%Prepared{} = prepared) do
    with :ok <- Startup.validate(prepared),
         {:ok, runtime} <- ProductionConversationRuntime.build(prepared),
         options <- assemble(prepared, runtime),
         :ok <- PollScheduler.validate(options.poll),
         :ok <- EventDispatchScheduler.validate(options.event_dispatch) do
      {:ok, options}
    else
      _failure -> {:error, :invalid_production_conversation_scheduler_options}
    end
  rescue
    _error -> {:error, :invalid_production_conversation_scheduler_options}
  catch
    _kind, _reason -> {:error, :invalid_production_conversation_scheduler_options}
  end

  def build(_prepared), do: {:error, :invalid_production_conversation_scheduler_options}

  defp assemble(prepared, runtime) do
    settings = prepared.scheduler_settings

    %__MODULE__{
      poll: %PollScheduler.Options{
        observer_client: runtime.observer_client,
        configuration: prepared.configuration,
        cycle_context: runtime.poll_context,
        ingestion_store: ObservationIngestionStore,
        clock: SystemClock,
        interval_ms: settings.poll_interval_ms,
        initial_delay_ms: settings.poll_interval_ms
      },
      event_dispatch: %EventDispatchScheduler.Options{
        configuration: prepared.configuration,
        cycle_context: runtime.event_dispatch_context,
        cycle_adapters: runtime.event_dispatch_adapters,
        cycle: EventDispatchCycle,
        clock: SystemClock,
        interval_ms: settings.event_dispatch_interval_ms,
        initial_delay_ms: settings.event_dispatch_interval_ms
      }
    }
  end
end

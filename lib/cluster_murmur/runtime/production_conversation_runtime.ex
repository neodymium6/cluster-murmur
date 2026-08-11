defmodule ClusterMurmur.Runtime.ProductionConversationRuntime do
  @moduledoc """
  Builds the fixed reusable live conversation contexts without starting work.

  One validated startup value is the only input. The builder constructs the
  reviewed live transports, finite responder schedule, production conversation
  adapters, read-only observer client, and durable event-dispatch adapters. It
  performs no clock read, persistence access, network request, random sample,
  worker start, or conversation action.
  """

  alias ClusterMurmur.Persistence.{EventDispatchStore, EventStore}

  alias ClusterMurmur.Runtime.{
    EventDispatchCycle,
    LiveDependencies,
    PollStarterCycle,
    ProductionConversationAdapters,
    ResponderTurnSchedule
  }

  alias ClusterMurmur.Startup
  alias ClusterMurmur.Startup.Prepared
  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.SharedInput
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer

  @live_dependency_keys LiveDependencies.__struct__() |> Map.keys()
  @live_dependency_key_count length(@live_dependency_keys)

  @derive {Inspect, only: []}
  @enforce_keys [
    :observer_client,
    :poll_context,
    :event_dispatch_context,
    :event_dispatch_adapters
  ]
  defstruct [
    :observer_client,
    :poll_context,
    :event_dispatch_context,
    :event_dispatch_adapters
  ]

  @type t :: %__MODULE__{
          observer_client: ClusterMurmur.Observers.Client.t(),
          poll_context: ClusterMurmur.Runtime.PollStarterCycle.Context.t(),
          event_dispatch_context: ClusterMurmur.Runtime.EventDispatchCycle.Context.t(),
          event_dispatch_adapters: ClusterMurmur.Runtime.EventDispatchCycle.Adapters.t()
        }

  @doc "Builds and preflights both production conversation cycle contexts."
  @spec build(term()) :: {:ok, t()} | {:error, :invalid_production_conversation_runtime}
  def build(%Prepared{} = prepared) do
    with :ok <- Startup.validate(prepared),
         {:ok, live} <- LiveDependencies.build(prepared),
         {:ok, conversation_adapters} <- ProductionConversationAdapters.build(),
         :ok <- validate_live_adapters(live, conversation_adapters),
         {:ok, schedule} <-
           ResponderTurnSchedule.build(
             prepared.configuration.conversation_defaults,
             prepared.responder_schedule_settings,
             live.generation_transport,
             live.publication_transport
           ),
         runtime <- assemble(prepared, live, conversation_adapters, schedule),
         :ok <- preflight(prepared, runtime) do
      {:ok, runtime}
    else
      _failure -> {:error, :invalid_production_conversation_runtime}
    end
  rescue
    _error -> {:error, :invalid_production_conversation_runtime}
  catch
    _kind, _reason -> {:error, :invalid_production_conversation_runtime}
  end

  def build(_prepared), do: {:error, :invalid_production_conversation_runtime}

  @doc false
  @spec validate_live_adapters(term(), term()) ::
          :ok | {:error, :invalid_production_conversation_runtime}
  def validate_live_adapters(
        %LiveDependencies{} = live,
        %AuthorizedConversationPipeline.Adapters{} = conversation_adapters
      ) do
    starter = conversation_adapters.starter
    responder = conversation_adapters.responder

    with true <- exact_live_dependencies?(live),
         :ok <- AuthorizedConversationPipeline.validate_adapters(conversation_adapters),
         true <- live.provider === starter.provider,
         true <- live.provider === responder.provider,
         true <- live.publisher === starter.publisher,
         true <- live.publisher === responder.publisher do
      :ok
    else
      _failure -> {:error, :invalid_production_conversation_runtime}
    end
  rescue
    _error -> {:error, :invalid_production_conversation_runtime}
  catch
    _kind, _reason -> {:error, :invalid_production_conversation_runtime}
  end

  def validate_live_adapters(_live, _conversation_adapters),
    do: {:error, :invalid_production_conversation_runtime}

  defp exact_live_dependencies?(live) do
    map_size(live) == @live_dependency_key_count and
      Enum.all?(@live_dependency_keys, &Map.has_key?(live, &1))
  end

  defp assemble(prepared, live, conversation_adapters, schedule) do
    shared_input = %SharedInput{
      configuration: prepared.configuration,
      cooldowns: %{},
      provider_settings: prepared.runtime_settings.provider_settings,
      webhook_settings: prepared.runtime_settings.webhook_settings,
      generation_transport: live.generation_transport,
      publication_transport: live.publication_transport
    }

    poll_context = %PollStarterCycle.Context{
      shared_input: shared_input,
      adapters: conversation_adapters.starter,
      conversation_runtime: %PollStarterCycle.ConversationRuntime{
        schedule: schedule,
        adapters: conversation_adapters
      }
    }

    event_dispatch_context = %EventDispatchCycle.Context{
      shared_input: shared_input,
      adapters: conversation_adapters.starter,
      conversation_runtime: %EventDispatchCycle.ConversationRuntime{
        schedule: schedule,
        adapters: conversation_adapters
      }
    }

    %__MODULE__{
      observer_client: live.observer_client,
      poll_context: poll_context,
      event_dispatch_context: event_dispatch_context,
      event_dispatch_adapters: %EventDispatchCycle.Adapters{
        dispatches: EventDispatchStore,
        events: EventStore,
        authorizer: EventTriggerAuthorizer
      }
    }
  end

  defp preflight(prepared, runtime) do
    with :ok <- PollStarterCycle.validate_runtime(prepared.configuration, runtime.poll_context),
         :ok <-
           EventDispatchCycle.validate_runtime(
             prepared.configuration,
             runtime.event_dispatch_context,
             runtime.event_dispatch_adapters
           ) do
      :ok
    end
  end
end

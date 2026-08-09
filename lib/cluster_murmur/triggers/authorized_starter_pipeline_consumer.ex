defmodule ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer do
  @moduledoc """
  Consumes each poll or durable-dispatch authorization through one preflighted
  starter pipeline input.

  The context contains one authorization-free input per planned match. The full
  bounded batch is validated before the dispatcher authorizes its first action.
  Each authorization is then inserted only for its stable position and is never
  returned from this boundary.
  """

  @behaviour ClusterMurmur.Triggers.AuthorizedStarterConsumer

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult

  alias ClusterMurmur.Triggers.{
    AuthorizedStarterPipeline,
    EventConversationIdentity,
    EventDispatchPlanner,
    EventTriggerAuthorizer,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, Input}
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization
  alias ClusterMurmur.Triggers.EventDispatchPlanner.Plan, as: EventDispatchPlan
  alias ClusterMurmur.Triggers.PollEventTriggerPlanner.Plan

  defmodule Context do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:entries, :adapters]
    defstruct [:entries, :adapters]

    @type t :: %__MODULE__{
            entries: [ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Entry.t()],
            adapters: ClusterMurmur.Triggers.AuthorizedStarterPipeline.Adapters.t()
          }
  end

  defmodule Entry do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:input, :event, :trigger, :executed_at]
    defstruct [:input, :event, :trigger, :executed_at]

    @type t :: %__MODULE__{
            input: ClusterMurmur.Triggers.AuthorizedStarterPipeline.Input.t(),
            event: ClusterMurmur.Events.Event.t(),
            trigger: ClusterMurmur.Triggers.EventTrigger.t(),
            executed_at: DateTime.t()
          }
  end

  @entry_keys Entry.__struct__() |> Map.keys()
  @entry_key_count length(@entry_keys)
  @context_keys Context.__struct__() |> Map.keys()
  @context_key_count length(@context_keys)
  @max_index 255

  @impl true
  def preflight(
        %Plan{} = plan,
        %PollResult{} = poll_result,
        %Configuration{} = configuration,
        %Context{} = context
      ) do
    with :ok <- PollEventTriggerPlanner.validate(plan, poll_result, configuration),
         true <- exact_context?(context),
         :ok <-
           validate_entries(
             context.entries,
             expected_matches(plan.entries),
             plan.executed_at,
             context.adapters,
             configuration,
             %{}
           ) do
      :ok
    else
      _failure -> {:error, :invalid_starter_context}
    end
  rescue
    _error -> {:error, :invalid_starter_context}
  catch
    _kind, _reason -> {:error, :invalid_starter_context}
  end

  def preflight(_plan, _poll_result, _configuration, _context),
    do: {:error, :invalid_starter_context}

  @doc "Preflights durable event-dispatch matches through the same fixed consumer."
  @spec preflight(term(), term(), term()) :: :ok | {:error, :invalid_starter_context}
  def preflight(
        %EventDispatchPlan{} = plan,
        %Configuration{} = configuration,
        %Context{} = context
      ) do
    with :ok <- EventDispatchPlanner.validate(plan, configuration),
         true <- exact_context?(context),
         :ok <-
           validate_entries(
             context.entries,
             expected_matches(plan.entries),
             plan.executed_at,
             context.adapters,
             configuration,
             %{}
           ) do
      :ok
    else
      _failure -> {:error, :invalid_starter_context}
    end
  rescue
    _error -> {:error, :invalid_starter_context}
  catch
    _kind, _reason -> {:error, :invalid_starter_context}
  end

  def preflight(_plan, _configuration, _context), do: {:error, :invalid_starter_context}

  @impl true
  def consume(%Authorization{} = authorization, index, %Context{} = context)
      when is_integer(index) and index >= 0 and index <= @max_index do
    with true <- exact_context?(context),
         :ok <- EventTriggerAuthorizer.validate(authorization),
         {:ok, %Entry{input: %Input{authorization: nil} = input} = entry} <-
           Enum.fetch(context.entries, index),
         true <- exact_entry?(entry),
         true <- correlated_authorization?(authorization, entry),
         true <- correlated_input?(input, entry),
         :ok <- AuthorizedStarterPipeline.validate_shared_input(input, context.adapters),
         :ok <- run_pipeline(%{input | authorization: authorization}, context.adapters) do
      :ok
    else
      _failure -> {:error, :starter_failed}
    end
  rescue
    _error -> {:error, :starter_failed}
  catch
    _kind, _reason -> {:error, :starter_failed}
  end

  def consume(_authorization, _index, _context), do: {:error, :starter_failed}

  defp validate_entries(
         [],
         [],
         _executed_at,
         _adapters,
         _configuration,
         _conversation_ids
       ),
       do: :ok

  defp validate_entries(
         [%Entry{input: %Input{authorization: nil} = input} = entry | entries],
         [{event, trigger} | matches],
         executed_at,
         %Adapters{} = adapters,
         configuration,
         conversation_ids
       ) do
    with true <- exact_entry?(entry),
         true <- entry.event === event,
         true <- entry.trigger === trigger,
         true <- entry.executed_at === executed_at,
         true <- correlated_input?(input, entry),
         true <- input.configuration === configuration,
         false <- Map.has_key?(conversation_ids, input.conversation_id),
         true <- not_before_match?(input.generated_at, event, executed_at),
         :ok <- AuthorizedStarterPipeline.validate_shared_input(input, adapters) do
      validate_entries(
        entries,
        matches,
        executed_at,
        adapters,
        configuration,
        Map.put(conversation_ids, input.conversation_id, true)
      )
    else
      _failure -> {:error, :invalid_starter_context}
    end
  end

  defp validate_entries(
         _entries,
         _matches,
         _executed_at,
         _adapters,
         _configuration,
         _conversation_ids
       ),
       do: {:error, :invalid_starter_context}

  defp expected_matches(entries) do
    Enum.flat_map(entries, fn entry ->
      Enum.map(entry.triggers, fn trigger -> {entry.event, trigger} end)
    end)
  end

  defp correlated_authorization?(authorization, entry) do
    plan = authorization.plan

    plan.event === entry.event and plan.trigger === entry.trigger and
      plan.executed_at === entry.executed_at
  end

  defp correlated_input?(input, entry) do
    case EventConversationIdentity.derive(entry.event, entry.trigger, entry.executed_at) do
      {:ok, conversation_id} -> input.conversation_id === conversation_id
      {:error, :invalid_event_conversation_identity} -> false
    end
  end

  defp not_before_match?(generated_at, event, executed_at) do
    latest_event_at =
      case event.observed_at do
        nil ->
          event.occurred_at

        observed_at ->
          if DateTime.compare(observed_at, event.occurred_at) == :lt,
            do: event.occurred_at,
            else: observed_at
      end

    DateTime.compare(generated_at, latest_event_at) in [:gt, :eq] and
      DateTime.compare(generated_at, executed_at) in [:gt, :eq]
  end

  defp run_pipeline(input, adapters) do
    case AuthorizedStarterPipeline.run(input, adapters) do
      {:ok, _completed} -> :ok
      {:continue, :reply, _recorded} -> :ok
      _failure -> {:error, :starter_failed}
    end
  end

  defp exact_context?(context) do
    map_size(context) == @context_key_count and
      Enum.all?(@context_keys, &Map.has_key?(context, &1))
  end

  defp exact_entry?(entry) do
    map_size(entry) == @entry_key_count and Enum.all?(@entry_keys, &Map.has_key?(entry, &1))
  end
end

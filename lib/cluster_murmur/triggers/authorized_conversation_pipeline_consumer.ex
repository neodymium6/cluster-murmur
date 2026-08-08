defmodule ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer do
  @moduledoc """
  Consumes poll authorizations through preflighted bounded conversations.

  The context contains one authorization-free conversation input per planned
  match. The complete batch is validated before the dispatcher authorizes its
  first action. Each durable authorization is inserted only at its stable
  position and is never returned from this boundary.
  """

  @behaviour ClusterMurmur.Triggers.AuthorizedStarterConsumer

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult

  alias ClusterMurmur.Triggers.{
    AuthorizedConversationPipeline,
    EventTriggerAuthorizer,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.{Adapters, Input}
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.Input, as: StarterInput
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization
  alias ClusterMurmur.Triggers.PollEventTriggerPlanner.Plan

  defmodule Entry do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:input, :event, :trigger, :executed_at]
    defstruct [:input, :event, :trigger, :executed_at]

    @type t :: %__MODULE__{
            input: ClusterMurmur.Triggers.AuthorizedConversationPipeline.Input.t(),
            event: ClusterMurmur.Events.Event.t(),
            trigger: ClusterMurmur.Triggers.EventTrigger.t(),
            executed_at: DateTime.t()
          }
  end

  defmodule Context do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:entries, :adapters]
    defstruct [:entries, :adapters]

    @type t :: %__MODULE__{
            entries: [ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.Entry.t()],
            adapters: ClusterMurmur.Triggers.AuthorizedConversationPipeline.Adapters.t()
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
           validate_inputs(
             context.entries,
             expected_matches(plan.entries),
             plan.executed_at,
             context.adapters,
             configuration,
             MapSet.new()
           ) do
      :ok
    else
      _failure -> {:error, :invalid_conversation_context}
    end
  rescue
    _error -> {:error, :invalid_conversation_context}
  catch
    _kind, _reason -> {:error, :invalid_conversation_context}
  end

  def preflight(_plan, _poll_result, _configuration, _context),
    do: {:error, :invalid_conversation_context}

  @impl true
  def consume(%Authorization{} = authorization, index, %Context{} = context)
      when is_integer(index) and index >= 0 and index <= @max_index do
    with true <- exact_context?(context),
         :ok <- EventTriggerAuthorizer.validate(authorization),
         {:ok,
          %Entry{
            input: %Input{starter: %StarterInput{authorization: nil} = starter} = input
          } = entry} <- Enum.fetch(context.entries, index),
         true <- exact_entry?(entry),
         true <- correlated_authorization?(authorization, entry),
         :ok <-
           AuthorizedConversationPipeline.validate_shared_runtime(
             input,
             context.adapters,
             authorization.plan.executed_at
           ),
         :ok <-
           run_pipeline(
             %{input | starter: %{starter | authorization: authorization}},
             context.adapters
           ) do
      :ok
    else
      _failure -> {:error, :conversation_failed}
    end
  rescue
    _error -> {:error, :conversation_failed}
  catch
    _kind, _reason -> {:error, :conversation_failed}
  end

  def consume(_authorization, _index, _context), do: {:error, :conversation_failed}

  defp validate_inputs([], [], _executed_at, _adapters, _configuration, _ids), do: :ok

  defp validate_inputs(
         [
           %Entry{
             input: %Input{starter: %StarterInput{authorization: nil} = starter} = input
           } = entry
           | entries
         ],
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
         true <- starter.configuration === configuration,
         false <- MapSet.member?(conversation_ids, starter.conversation_id),
         true <- not_before_match?(starter.generated_at, event, executed_at),
         :ok <-
           AuthorizedConversationPipeline.validate_shared_runtime(input, adapters, executed_at) do
      validate_inputs(
        entries,
        matches,
        executed_at,
        adapters,
        configuration,
        MapSet.put(conversation_ids, starter.conversation_id)
      )
    else
      _failure -> {:error, :invalid_conversation_context}
    end
  end

  defp validate_inputs(_inputs, _events, _executed_at, _adapters, _configuration, _ids),
    do: {:error, :invalid_conversation_context}

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
    case AuthorizedConversationPipeline.run(input, adapters) do
      {:ok, _completed} -> :ok
      {:ok, :no_reply, _result} -> :ok
      {:continue, _continuation} -> :ok
      _failure -> {:error, :conversation_failed}
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

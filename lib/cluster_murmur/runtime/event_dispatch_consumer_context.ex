defmodule ClusterMurmur.Runtime.EventDispatchConsumerContext do
  @moduledoc false

  alias ClusterMurmur.Config.Configuration

  alias ClusterMurmur.Runtime.EventDispatchCycle.{Context, ConversationRuntime}
  alias ClusterMurmur.Runtime.ResponderTurnSchedule

  alias ClusterMurmur.Triggers.{
    AuthorizedConversationPipeline,
    AuthorizedConversationPipelineConsumer,
    AuthorizedStarterPipelineConsumer,
    EventConversationIdentity
  }

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.Input, as: ConversationInput

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.Context,
    as: ConversationConsumerContext

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.Entry,
    as: ConversationConsumerEntry

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Input, SharedInput}

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Context,
    as: StarterConsumerContext

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Entry,
    as: StarterConsumerEntry

  alias ClusterMurmur.Triggers.EventDispatchPlanner.Plan

  @validation_at ~U[2026-01-01 00:00:00.000000Z]
  @conversation_runtime_keys ConversationRuntime.__struct__() |> Map.keys()
  @conversation_runtime_key_count length(@conversation_runtime_keys)

  @spec prepare(Plan.t(), Configuration.t(), Context.t(), DateTime.t()) ::
          {:ok, module(), struct()} | {:error, :invalid_event_dispatch_cycle}
  def prepare(
        %Plan{} = plan,
        %Configuration{} = configuration,
        %Context{} = context,
        %DateTime{} = now
      ) do
    with {:ok, consumer, consumer_context} <- build(plan, context, now),
         :ok <- preflight(consumer, plan, configuration, consumer_context) do
      {:ok, consumer, consumer_context}
    end
  end

  def prepare(_plan, _configuration, _context, _now),
    do: {:error, :invalid_event_dispatch_cycle}

  @spec validate_conversation_runtime(Context.t()) ::
          :ok | {:error, :invalid_event_dispatch_cycle}
  def validate_conversation_runtime(%Context{conversation_runtime: nil}), do: :ok

  def validate_conversation_runtime(%Context{
        adapters: starter_adapters,
        shared_input: shared,
        conversation_runtime: %ConversationRuntime{} = runtime
      }) do
    with true <- exact_conversation_runtime?(runtime),
         true <- runtime.adapters.starter === starter_adapters,
         {:ok, turns} <- ResponderTurnSchedule.project(runtime.schedule, @validation_at),
         starter = build_input(shared, "conversation-validation", @validation_at),
         input = %ConversationInput{starter: starter, responder_turns: turns},
         :ok <-
           AuthorizedConversationPipeline.validate_shared_runtime(
             input,
             runtime.adapters,
             @validation_at
           ) do
      :ok
    else
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  def validate_conversation_runtime(_context),
    do: {:error, :invalid_event_dispatch_cycle}

  defp build(plan, context, now) do
    with {:ok, inputs} <- build_inputs(plan.entries, context.shared_input, now) do
      case context.conversation_runtime do
        nil -> build_starter(plan, inputs, context.adapters, now)
        %ConversationRuntime{} = runtime -> build_conversation(plan, inputs, runtime, now)
        _invalid -> {:error, :invalid_event_dispatch_cycle}
      end
    end
  end

  defp build_inputs(entries, shared, now) do
    entries
    |> expected_matches()
    |> Enum.reduce_while({:ok, []}, fn {event, trigger}, {:ok, inputs} ->
      case EventConversationIdentity.derive(event, trigger, now) do
        {:ok, conversation_id} ->
          {:cont, {:ok, [build_input(shared, conversation_id, now) | inputs]}}

        _failure ->
          {:halt, {:error, :invalid_event_dispatch_cycle}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  defp build_starter(plan, inputs, adapters, now) do
    matches = expected_matches(plan.entries)

    if length(inputs) == length(matches) do
      entries =
        Enum.zip_with(inputs, matches, fn input, {event, trigger} ->
          %StarterConsumerEntry{input: input, event: event, trigger: trigger, executed_at: now}
        end)

      {:ok, AuthorizedStarterPipelineConsumer,
       %StarterConsumerContext{entries: entries, adapters: adapters}}
    else
      {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp build_conversation(plan, inputs, runtime, now) do
    with {:ok, turns} <- ResponderTurnSchedule.project(runtime.schedule, now),
         matches <- expected_matches(plan.entries),
         true <- length(inputs) == length(matches) do
      entries =
        Enum.zip_with(inputs, matches, fn starter, {event, trigger} ->
          %ConversationConsumerEntry{
            input: %ConversationInput{starter: starter, responder_turns: turns},
            event: event,
            trigger: trigger,
            executed_at: now
          }
        end)

      {:ok, AuthorizedConversationPipelineConsumer,
       %ConversationConsumerContext{entries: entries, adapters: runtime.adapters}}
    else
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp expected_matches(entries) do
    Enum.flat_map(entries, fn entry ->
      Enum.map(entry.triggers, fn trigger -> {entry.event, trigger} end)
    end)
  end

  defp build_input(%SharedInput{} = shared, conversation_id, now) do
    %Input{
      authorization: nil,
      configuration: shared.configuration,
      cooldowns: shared.cooldowns,
      conversation_id: conversation_id,
      provider_settings: shared.provider_settings,
      webhook_settings: shared.webhook_settings,
      generated_at: now,
      publication_started_at: now,
      publication_completed_at: now,
      generation_transport: shared.generation_transport,
      publication_transport: shared.publication_transport
    }
  end

  defp preflight(consumer, plan, configuration, context) do
    case consumer.preflight(plan, configuration, context) do
      :ok -> :ok
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_cycle}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_cycle}
  end

  defp exact_conversation_runtime?(runtime) do
    map_size(runtime) == @conversation_runtime_key_count and
      Enum.all?(@conversation_runtime_keys, &Map.has_key?(runtime, &1))
  end
end

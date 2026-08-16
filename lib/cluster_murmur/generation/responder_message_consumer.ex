defmodule ClusterMurmur.Generation.ResponderMessageConsumer do
  @moduledoc """
  Synchronously consumes one claimed responder selection through persistence.

  The continuation dispatcher reserves a reply's LLM call durably before this
  trusted boundary receives the sampled plan. This consumer then projects only
  bounded history and optional allowlisted event facts, calls one provider with
  a safe fallback, and appends the message without counting the reservation
  twice. A no-reply plan has already closed its conversation and performs no I/O
  here.
  """

  @behaviour ClusterMurmur.Conversations.ResponderContinuationConsumer

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer.Delivery
  alias ClusterMurmur.Conversations.ResponderContinuationPlanner
  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.{Input, Plan}

  alias ClusterMurmur.Conversations.ResponderTurnFinisher.Continuation,
    as: ResponderContinuation

  alias ClusterMurmur.Conversations.StarterReplyFinisher.Continuation,
    as: StarterContinuation

  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Generation.{
    Context,
    ContextValidator,
    ConversationLine,
    CreativeContext,
    FactProjector,
    FallbackGenerator,
    PersonaProjection,
    PersonaProjectionValidator,
    PromptAssembler,
    ProviderResultResolver,
    ProviderSettings
  }

  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    MessageRecord,
    MessageRecordValidator
  }

  alias ClusterMurmur.Personas.Persona
  alias ClusterMurmur.Runtime.OperationalTelemetry

  @discord_content_limit 2_000
  @input_keys Input.__struct__() |> Map.keys()
  @input_key_count length(@input_keys)
  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  defmodule ConsumerContext do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [
      :input,
      :provider_settings,
      :inserted_at,
      :provider,
      :transport,
      :conversation_store,
      :message_store
    ]
    defstruct [
      :input,
      :provider_settings,
      :inserted_at,
      :provider,
      :transport,
      :conversation_store,
      :message_store
    ]

    @type t :: %__MODULE__{
            input: ClusterMurmur.Conversations.ResponderContinuationPlanner.Input.t(),
            provider_settings: ClusterMurmur.Generation.ProviderSettings.t(),
            inserted_at: DateTime.t(),
            provider: module(),
            transport: function(),
            conversation_store: module(),
            message_store: module()
          }
  end

  @context_keys ConsumerContext.__struct__() |> Map.keys()
  @context_key_count length(@context_keys)

  @impl true
  def preflight(%Input{} = input, %ConsumerContext{} = context) do
    with true <- exact_input?(input),
         true <- exact_context?(context),
         true <- context.input === input,
         :ok <- Configuration.validate(input.configuration),
         :ok <- validate_settings(context.provider_settings, input.configuration),
         :ok <- validate_inserted_at(context.inserted_at, input),
         :ok <- validate_adapters(context) do
      :ok
    else
      _failure -> {:error, :invalid_responder_message_context}
    end
  rescue
    _error -> {:error, :invalid_responder_message_context}
  catch
    _kind, _reason -> {:error, :invalid_responder_message_context}
  end

  def preflight(_input, _context), do: {:error, :invalid_responder_message_context}

  @impl true
  def consume(%Plan{} = plan, %ConsumerContext{} = context) do
    with :ok <- preflight(plan.input, context),
         true <- exact_plan?(plan),
         result when result == :ok or is_tuple(result) <- consume_outcome(plan, context) do
      result
    else
      _failure -> {:error, :responder_message_failed}
    end
  rescue
    _error -> {:error, :responder_message_failed}
  catch
    _kind, _reason -> {:error, :responder_message_failed}
  end

  def consume(_plan, _context), do: {:error, :responder_message_failed}

  defp consume_outcome(%Plan{outcome: :no_reply, responder: nil} = plan, context) do
    waiting = plan.input.continuation.conversation
    expected = %{waiting | status: :completed, completed_at: plan.input.planned_at}

    with true <- plan.conversation === expected,
         :ok <- ConversationRecordValidator.validate(plan.conversation),
         :ok <- context.conversation_store.confirm_completed(plan.conversation) do
      :ok
    else
      _failure -> {:error, :responder_message_failed}
    end
  end

  defp consume_outcome(%Plan{outcome: :reply, responder: %Persona{}} = plan, context) do
    with :ok <- ResponderContinuationPlanner.validate_reply_plan(plan),
         :ok <- consume_durable_selection(context, plan),
         {:ok, generation_context} <- build_generation_context(plan),
         {:ok, request} <- PromptAssembler.assemble(generation_context),
         provider_result <- call_provider(context, request),
         {:ok, decision} <-
           ProviderResultResolver.resolve(
             provider_result,
             generation_context.persona,
             @discord_content_limit
           ),
         decision <- OperationalTelemetry.generation_decision(decision),
         {:ok, generated} <- build_message(decision, plan, context.inserted_at),
         {:ok, {message, conversation}} <- append_reserved(context, plan, generated),
         {:ok, delivery} <- validate_append_result(message, conversation, plan, generated) do
      {:ok, delivery}
    else
      _failure -> {:error, :responder_message_failed}
    end
  end

  defp consume_outcome(_plan, _context), do: {:error, :responder_message_failed}

  defp build_generation_context(plan) do
    input = plan.input

    persona = %PersonaProjection{
      display_name: plan.responder.display_name,
      instructions: plan.responder.prompt
    }

    with {:ok, event} <- root_event(input.continuation),
         :ok <- PersonaProjectionValidator.validate(persona),
         {:ok, facts} <-
           FactProjector.project_for_generation(event, input.configuration.presentation),
         {:ok, history} <- project_history(input.conversation.messages, input.configuration),
         {conversation_kind, mood} <- framing(event, plan.binding.group),
         context = %Context{
           persona: persona,
           facts: facts,
           creative_context: %CreativeContext{
             conversation_kind: conversation_kind,
             mood: mood
           },
           conversation: history
         },
         :ok <- ContextValidator.validate(context) do
      {:ok, context}
    else
      _failure -> {:error, :responder_message_failed}
    end
  end

  defp framing(%{source: "stochastic"}, _binding_group), do: {"ambient", "engaged"}
  defp framing(_event, binding_group), do: {binding_group, "responsive"}

  defp project_history(messages, configuration) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, lines} ->
      case Map.fetch(configuration.personas.personas, message.persona_id) do
        {:ok, %Persona{} = speaker} ->
          line = %ConversationLine{
            speaker: speaker.display_name,
            content: message.content,
            inserted_at: message.inserted_at
          }

          {:cont, {:ok, [line | lines]}}

        _failure ->
          {:halt, {:error, :responder_message_failed}}
      end
    end)
    |> reverse_history()
  end

  defp reverse_history({:ok, lines}), do: {:ok, Enum.reverse(lines)}
  defp reverse_history(error), do: error

  defp call_provider(context, request) do
    context.provider.generate(request, context.provider_settings, context.transport)
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp consume_durable_selection(context, plan) do
    context.conversation_store.consume_generation(plan.conversation, plan.responder.id)
  rescue
    _error -> {:error, :responder_message_failed}
  catch
    _kind, _reason -> {:error, :responder_message_failed}
  end

  defp build_message({:llm, content}, plan, inserted_at),
    do: validate_generated(message(plan, :llm, content, inserted_at))

  defp build_message({:fallback, _reason}, plan, inserted_at) do
    with {:ok, event} <- root_event(plan.input.continuation) do
      event
      |> FallbackGenerator.generate(plan.conversation.id, plan.responder.id, inserted_at)
      |> normalize_fallback()
    else
      _failure -> {:error, :responder_message_failed}
    end
  end

  defp root_event(%StarterContinuation{} = continuation) do
    {:ok,
     continuation.recorded.published.started.plan.persisted.generated.plan.started.plan.authorization.plan.event}
  rescue
    _error -> {:error, :responder_message_failed}
  end

  defp root_event(%ResponderContinuation{} = continuation) do
    continuation.recorded.published.started.plan.delivery.plan.input.continuation
    |> root_event()
  rescue
    _error -> {:error, :responder_message_failed}
  end

  defp root_event(_continuation), do: {:error, :responder_message_failed}

  defp validate_generated(%Message{} = message) do
    if MessageValidator.validate(message) == :ok,
      do: {:ok, message},
      else: {:error, :responder_message_failed}
  end

  defp normalize_fallback({:ok, %Message{} = message}), do: {:ok, message}
  defp normalize_fallback(_failure), do: {:error, :responder_message_failed}

  defp message(plan, origin, content, inserted_at) do
    %Message{
      conversation_id: plan.conversation.id,
      persona_id: plan.responder.id,
      origin: origin,
      content: content,
      discord_message_id: nil,
      inserted_at: inserted_at
    }
  end

  defp append_reserved(context, plan, generated) do
    context.message_store.append_reserved(plan.conversation, generated)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp validate_append_result(
         %MessageRecord{} = message,
         %ConversationRecord{} = conversation,
         plan,
         generated
       ) do
    expected_conversation = %{plan.conversation | turn_count: plan.conversation.turn_count + 1}

    if correlated_message?(message, generated) and conversation === expected_conversation and
         ConversationRecordValidator.validate_active(conversation) == :ok do
      delivery = %Delivery{plan: plan, message: message, conversation: conversation}

      if ResponderContinuationConsumer.validate_delivery(delivery, plan) == :ok,
        do: {:ok, delivery},
        else: {:error, :responder_message_failed}
    else
      {:error, :responder_message_failed}
    end
  end

  defp validate_append_result(_message, _conversation, _plan, _generated),
    do: {:error, :responder_message_failed}

  defp correlated_message?(record, generated) do
    MessageRecordValidator.validate(record) == :ok and
      record.conversation_id === generated.conversation_id and
      record.persona_id === generated.persona_id and record.origin === generated.origin and
      record.content === generated.content and
      record.discord_message_id === generated.discord_message_id and
      DateTime.compare(record.inserted_at, generated.inserted_at) == :eq
  end

  defp validate_settings(%ProviderSettings{} = settings, configuration) do
    llm = configuration.llm

    if ProviderSettings.validate(settings) == :ok and settings.provider === llm.provider and
         settings.timeout_ms === llm.timeout_ms and
         settings.max_output_tokens === llm.max_output_tokens and
         settings.reasoning_effort === llm.reasoning_effort,
       do: :ok,
       else: {:error, :invalid_responder_message_context}
  end

  defp validate_settings(_settings, _configuration),
    do: {:error, :invalid_responder_message_context}

  defp validate_inserted_at(inserted_at, input) do
    if DateTimeValidator.validate_storage_utc(inserted_at) == :ok and
         DateTime.compare(inserted_at, input.planned_at) in [:gt, :eq] and
         DateTime.compare(inserted_at, input.conversation.last_message_at) in [:gt, :eq],
       do: :ok,
       else: {:error, :invalid_responder_message_context}
  end

  defp validate_adapters(context) do
    if is_atom(context.provider) and Code.ensure_loaded?(context.provider) and
         function_exported?(context.provider, :generate, 3) and is_function(context.transport, 1) and
         is_atom(context.conversation_store) and Code.ensure_loaded?(context.conversation_store) and
         function_exported?(context.conversation_store, :consume_generation, 2) and
         function_exported?(context.conversation_store, :confirm_completed, 1) and
         is_atom(context.message_store) and Code.ensure_loaded?(context.message_store) and
         function_exported?(context.message_store, :append_reserved, 2),
       do: :ok,
       else: {:error, :invalid_responder_message_context}
  end

  defp exact_input?(input) do
    map_size(input) == @input_key_count and Enum.all?(@input_keys, &Map.has_key?(input, &1))
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end

  defp exact_context?(context) do
    map_size(context) == @context_key_count and
      Enum.all?(@context_keys, &Map.has_key?(context, &1))
  end
end

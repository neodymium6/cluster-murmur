defmodule ClusterMurmur.Conversations.ResponderContinuationPlanner do
  @moduledoc """
  Selects and synchronously dispatches one bounded responder continuation.

  Historical starter cooldown facts and the current responder cooldown view are
  separate inputs. The selected persona or explicit no-reply outcome crosses
  directly into one preflighted consumer and is never returned as a reusable
  authorization capability.
  """

  alias ClusterMurmur.Config.Configuration

  alias ClusterMurmur.Conversations.{
    Conversation,
    ReplyGateDecision,
    StarterReplyFinisher
  }

  alias ClusterMurmur.Conversations.Validator, as: ConversationValidator
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer.Delivery
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Messages.Message

  alias ClusterMurmur.Persistence.{
    ConversationRecordValidator,
    MessageRecordValidator,
    PersonaCooldownRecord,
    PersonaCooldownRecordValidator
  }

  alias ClusterMurmur.Personas.{
    Binding,
    BindingValidator,
    Persona,
    ResponderCandidateProjector,
    ResponderSelector
  }

  alias ClusterMurmur.Conversations.StarterReplyFinisher.Continuation
  alias ClusterMurmur.Personas.Validator, as: PersonaValidator

  defmodule Input do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [
      :continuation,
      :configuration,
      :starter_cooldowns,
      :current_cooldowns,
      :webhook_settings,
      :conversation,
      :budget,
      :planned_at,
      :policy,
      :no_reply_weight
    ]
    defstruct [
      :continuation,
      :configuration,
      :starter_cooldowns,
      :current_cooldowns,
      :webhook_settings,
      :conversation,
      :budget,
      :planned_at,
      :policy,
      :no_reply_weight
    ]

    @type t :: %__MODULE__{
            continuation: ClusterMurmur.Conversations.StarterReplyFinisher.Continuation.t(),
            configuration: ClusterMurmur.Config.Configuration.t(),
            starter_cooldowns: map(),
            current_cooldowns: map(),
            webhook_settings: ClusterMurmur.Discord.WebhookSettings.t(),
            conversation: ClusterMurmur.Conversations.Conversation.t(),
            budget: ClusterMurmur.Conversations.Budget.t(),
            planned_at: DateTime.t(),
            policy: ClusterMurmur.Personas.ResponderPolicy.t(),
            no_reply_weight: number()
          }
  end

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: [:outcome, :planned_at]}
    @enforce_keys [
      :input,
      :binding,
      :outcome,
      :responder,
      :conversation,
      :planned_at
    ]
    defstruct [:input, :binding, :outcome, :responder, :conversation, :planned_at]

    @type t :: %__MODULE__{
            input: ClusterMurmur.Conversations.ResponderContinuationPlanner.Input.t(),
            binding: ClusterMurmur.Personas.Binding.t(),
            outcome: :reply | :no_reply,
            responder: ClusterMurmur.Personas.Persona.t() | nil,
            conversation: ClusterMurmur.Persistence.ConversationRecord.t(),
            planned_at: DateTime.t()
          }
  end

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:outcome, :status, :reason]}
    @enforce_keys [:outcome, :status, :reason, :delivery]
    defstruct [:outcome, :status, :reason, :delivery]

    @type t :: %__MODULE__{
            outcome: :reply | :no_reply,
            status: :dispatched | :failed,
            reason: :dispatch_failed | nil,
            delivery: ClusterMurmur.Conversations.ResponderContinuationConsumer.Delivery.t() | nil
          }
  end

  @input_keys Input.__struct__() |> Map.keys()
  @input_key_count length(@input_keys)
  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)
  @max_float DomainLimits.max_float()

  @type error :: :invalid_responder_continuation

  @doc "Selects one outcome and immediately crosses into a preflighted consumer."
  @spec dispatch(term(), module(), module(), module(), term()) ::
          {:ok, Result.t()} | {:error, error()}
  def dispatch(%Input{} = input, random, claim_store, consumer, consumer_context)
      when is_atom(random) and is_atom(claim_store) and is_atom(consumer) do
    with {:ok, binding, candidates} <- prepare(input),
         :ok <- validate_claim_store(claim_store),
         :ok <- validate_consumer(consumer),
         :ok <- preflight_consumer(consumer, input, consumer_context),
         {:ok, outcome} <-
           ResponderSelector.select(
             %ReplyGateDecision{outcome: :reply},
             candidates,
             input.no_reply_weight,
             random
           ),
         {:ok, responder} <- resolve_outcome(outcome, input.configuration),
         {:ok, claimed} <-
           claim_once(
             claim_store,
             input.continuation.conversation,
             outcome,
             input.planned_at
           ) do
      plan = %Plan{
        input: input,
        binding: binding,
        outcome: outcome_kind(outcome),
        responder: responder,
        conversation: claimed,
        planned_at: input.planned_at
      }

      {:ok, consume_one(consumer, plan, consumer_context)}
    else
      _failure -> {:error, :invalid_responder_continuation}
    end
  rescue
    _error -> {:error, :invalid_responder_continuation}
  catch
    _kind, _reason -> {:error, :invalid_responder_continuation}
  end

  def dispatch(_input, _random, _claim_store, _consumer, _consumer_context),
    do: {:error, :invalid_responder_continuation}

  @doc "Revalidates one exact claimed reply plan and its deterministic eligibility."
  @spec validate_reply_plan(term()) :: :ok | {:error, error()}
  def validate_reply_plan(%Plan{outcome: :reply, responder: %Persona{} = responder} = plan) do
    waiting = plan.input.continuation.conversation

    expected_conversation = %{
      waiting
      | status: :generating,
        llm_call_count: waiting.llm_call_count + 1
    }

    with true <- exact_plan?(plan),
         {:ok, binding, candidates} <- prepare(plan.input),
         true <- plan.binding === binding,
         true <- plan.planned_at === plan.input.planned_at,
         true <- plan.conversation === expected_conversation,
         :ok <- ConversationRecordValidator.validate_active(plan.conversation),
         true <- plan.input.configuration.personas.personas[responder.id] === responder,
         true <- Enum.any?(candidates, &(&1.persona_id === responder.id)) do
      :ok
    else
      _failure -> {:error, :invalid_responder_continuation}
    end
  rescue
    _error -> {:error, :invalid_responder_continuation}
  catch
    _kind, _reason -> {:error, :invalid_responder_continuation}
  end

  def validate_reply_plan(_plan), do: {:error, :invalid_responder_continuation}

  defp prepare(%Input{} = input) do
    with true <- exact_input?(input),
         :ok <-
           StarterReplyFinisher.validate_continuation(
             input.continuation,
             input.configuration,
             input.starter_cooldowns,
             input.webhook_settings
           ),
         :ok <- correlate_current_starter_cooldown(input),
         :ok <- correlate_conversation(input.continuation, input.conversation),
         true <-
           DateTime.compare(input.planned_at, input.conversation.last_message_at) in [:eq, :gt],
         true <- valid_no_reply_weight?(input.no_reply_weight),
         {:ok, binding} <- resolve_binding(input.continuation, input.configuration),
         {:ok, candidates} <-
           ResponderCandidateProjector.project(
             binding,
             input.configuration.personas.personas,
             input.current_cooldowns,
             input.conversation,
             input.budget,
             input.planned_at,
             input.policy
           ) do
      {:ok, binding, candidates}
    else
      _failure -> {:error, :invalid_responder_continuation}
    end
  end

  defp prepare(_input), do: {:error, :invalid_responder_continuation}

  defp correlate_current_starter_cooldown(%Input{} = input) do
    recorded = input.continuation.recorded.cooldown

    case Map.fetch(input.current_cooldowns, recorded.persona_id) do
      {:ok, %PersonaCooldownRecord{} = current} ->
        if PersonaCooldownRecordValidator.validate(current) == :ok and
             current.persona_id === recorded.persona_id and current_not_older?(current, recorded),
           do: :ok,
           else: {:error, :invalid_responder_continuation}

      _failure ->
        {:error, :invalid_responder_continuation}
    end
  end

  defp current_not_older?(current, recorded) do
    case DateTime.compare(current.last_spoken_at, recorded.last_spoken_at) do
      :gt -> true
      :eq -> DateTime.compare(current.cooldown_until, recorded.cooldown_until) == :eq
      :lt -> false
    end
  end

  defp correlate_conversation(%Continuation{} = continuation, %Conversation{} = conversation) do
    waiting = continuation.conversation
    published = continuation.recorded.published.message

    if ConversationValidator.validate(conversation) == :ok and
         ConversationRecordValidator.validate_active(waiting) == :ok and
         MessageRecordValidator.validate(published) == :ok and waiting.status === :waiting and
         conversation.id === waiting.id and conversation.root_event_id === waiting.root_event_id and
         conversation.status === waiting.status and conversation.started_at === waiting.started_at and
         conversation.turn_count === waiting.turn_count and
         conversation.llm_call_count === waiting.llm_call_count and
         conversation.participants === [published.persona_id] and
         last_message_matches?(conversation, published),
       do: :ok,
       else: {:error, :invalid_responder_continuation}
  end

  defp correlate_conversation(_continuation, _conversation),
    do: {:error, :invalid_responder_continuation}

  defp last_message_matches?(%Conversation{messages: []}, _published), do: false

  defp last_message_matches?(conversation, published) do
    last = List.last(conversation.messages)

    last === %Message{
      conversation_id: published.conversation_id,
      persona_id: published.persona_id,
      origin: published.origin,
      content: published.content,
      discord_message_id: published.discord_message_id,
      inserted_at: published.inserted_at
    }
  end

  defp resolve_binding(continuation, configuration) do
    upstream =
      continuation.recorded.published.started.plan.persisted.generated.plan.started.plan.binding

    with :ok <- BindingValidator.validate(upstream),
         {:ok, %Binding{} = configured} <-
           Map.fetch(configuration.bindings.bindings, upstream.id),
         true <- configured === upstream do
      {:ok, configured}
    else
      _failure -> {:error, :invalid_responder_continuation}
    end
  end

  defp resolve_outcome(:no_reply, _configuration), do: {:ok, nil}

  defp resolve_outcome({:reply, persona_id}, %Configuration{} = configuration) do
    case Map.fetch(configuration.personas.personas, persona_id) do
      {:ok, %Persona{} = persona} ->
        if PersonaValidator.validate(persona) == :ok,
          do: {:ok, persona},
          else: {:error, :invalid_responder_continuation}

      _failure ->
        {:error, :invalid_responder_continuation}
    end
  end

  defp resolve_outcome(_outcome, _configuration),
    do: {:error, :invalid_responder_continuation}

  defp validate_consumer(consumer) do
    if Code.ensure_loaded?(consumer) and function_exported?(consumer, :preflight, 2) and
         function_exported?(consumer, :consume, 2),
       do: :ok,
       else: {:error, :invalid_responder_continuation}
  end

  defp validate_claim_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :complete, 2) and
         function_exported?(store, :claim_generation, 2),
       do: :ok,
       else: {:error, :invalid_responder_continuation}
  end

  defp claim_once(store, waiting, {:reply, persona_id}, _planned_at) do
    with {:ok, claimed} <- safe_claim(store, waiting, persona_id),
         expected = %{
           waiting
           | status: :generating,
             llm_call_count: waiting.llm_call_count + 1
         },
         true <- claimed === expected,
         :ok <- ConversationRecordValidator.validate_active(claimed) do
      {:ok, claimed}
    else
      _failure -> {:error, :invalid_responder_continuation}
    end
  end

  defp claim_once(store, waiting, :no_reply, planned_at) do
    with {:ok, completed} <- safe_complete(store, waiting, planned_at),
         expected = %{waiting | status: :completed, completed_at: planned_at},
         true <- completed === expected,
         :ok <- ConversationRecordValidator.validate(completed) do
      {:ok, completed}
    else
      _failure -> {:error, :invalid_responder_continuation}
    end
  end

  defp claim_once(_store, _waiting, _outcome, _planned_at),
    do: {:error, :invalid_responder_continuation}

  defp safe_claim(store, waiting, persona_id) do
    store.claim_generation(waiting, persona_id)
  rescue
    _error -> {:error, :invalid_responder_continuation}
  catch
    _kind, _reason -> {:error, :invalid_responder_continuation}
  end

  defp safe_complete(store, waiting, completed_at) do
    store.complete(waiting, completed_at)
  rescue
    _error -> {:error, :invalid_responder_continuation}
  catch
    _kind, _reason -> {:error, :invalid_responder_continuation}
  end

  defp preflight_consumer(consumer, input, context) do
    case consumer.preflight(input, context) do
      :ok -> :ok
      _failure -> {:error, :invalid_responder_continuation}
    end
  rescue
    _error -> {:error, :invalid_responder_continuation}
  catch
    _kind, _reason -> {:error, :invalid_responder_continuation}
  end

  defp consume_one(consumer, plan, context) do
    case consumer.consume(plan, context) do
      :ok when plan.outcome == :no_reply ->
        result(plan, :dispatched, nil, nil)

      {:ok, %Delivery{} = delivery} when plan.outcome == :reply ->
        if ResponderContinuationConsumer.validate_delivery(delivery, plan) == :ok,
          do: result(plan, :dispatched, nil, delivery),
          else: result(plan, :failed, :dispatch_failed, nil)

      _failure ->
        result(plan, :failed, :dispatch_failed, nil)
    end
  rescue
    _error -> result(plan, :failed, :dispatch_failed, nil)
  catch
    _kind, _reason -> result(plan, :failed, :dispatch_failed, nil)
  end

  defp result(plan, status, reason, delivery) do
    %Result{outcome: plan.outcome, status: status, reason: reason, delivery: delivery}
  end

  defp outcome_kind(:no_reply), do: :no_reply
  defp outcome_kind({:reply, _persona_id}), do: :reply

  defp valid_no_reply_weight?(weight) when is_integer(weight),
    do: weight > 0 and weight <= @max_float

  defp valid_no_reply_weight?(weight) when is_float(weight),
    do: weight == weight and weight > 0 and weight <= @max_float

  defp valid_no_reply_weight?(_weight), do: false

  defp exact_input?(input) do
    map_size(input) == @input_key_count and Enum.all?(@input_keys, &Map.has_key?(input, &1))
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end
end

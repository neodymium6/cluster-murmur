defmodule ClusterMurmur.Runtime.ResponderConversationInitializer do
  @moduledoc """
  Builds the first responder-runner input from a proven starter continuation.

  This pure boundary projects the published starter message into bounded
  runtime memory, advances the current cooldown view, and derives immutable
  budget and continuity policy only from versioned configuration. It performs
  no selection, persistence, provider call, or publication.
  """

  alias ClusterMurmur.Config.{Configuration, ConversationDefaults}

  alias ClusterMurmur.Conversations.{
    Conversation,
    StarterReplyFinisher
  }

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.Input, as: ContinuationInput
  alias ClusterMurmur.Conversations.Validator, as: ConversationValidator
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Generation.{ProviderSettings}
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Personas.{ResponderCandidateProjector, StarterCandidateProjector}
  alias ClusterMurmur.Runtime.ResponderConversationRunner
  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn

  defmodule Input do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [
      :continuation,
      :configuration,
      :starter_cooldowns,
      :webhook_settings,
      :provider_settings,
      :turns
    ]
    defstruct [
      :continuation,
      :configuration,
      :starter_cooldowns,
      :webhook_settings,
      :provider_settings,
      :turns
    ]

    @type t :: %__MODULE__{
            continuation: ClusterMurmur.Conversations.StarterReplyFinisher.Continuation.t(),
            configuration: ClusterMurmur.Config.Configuration.t(),
            starter_cooldowns: map(),
            webhook_settings: ClusterMurmur.Discord.WebhookSettings.t(),
            provider_settings: ClusterMurmur.Generation.ProviderSettings.t(),
            turns: [ClusterMurmur.Runtime.ResponderConversationRunner.Turn.t()]
          }
  end

  @input_keys Input.__struct__() |> Map.keys()
  @input_key_count length(@input_keys)

  @doc "Projects one exact starter continuation into a responder-runner input."
  @spec initialize(Input.t()) ::
          {:ok, ResponderConversationRunner.Input.t()}
          | {:error, :invalid_responder_conversation_initialization}
  def initialize(%Input{} = input) do
    with true <- exact_input?(input),
         %Configuration{} = configuration <- input.configuration,
         %StarterReplyFinisher.Continuation{} = continuation <- input.continuation,
         :ok <- Configuration.validate(configuration),
         :ok <- StarterCandidateProjector.validate_cooldowns(input.starter_cooldowns),
         :ok <-
           StarterReplyFinisher.validate_continuation(
             continuation,
             configuration,
             input.starter_cooldowns,
             input.webhook_settings
           ),
         :ok <- validate_provider_settings(input.provider_settings, configuration),
         {:ok, planned_at} <- first_planned_at(input.turns, continuation),
         {:ok, budget} <- ConversationDefaults.to_budget(configuration.conversation_defaults),
         {:ok, policy} <-
           ConversationDefaults.to_responder_policy(configuration.conversation_defaults),
         {:ok, conversation} <- project_conversation(continuation),
         {:ok, current_cooldowns} <-
           project_cooldowns(continuation, configuration, input.starter_cooldowns) do
      continuation_input = %ContinuationInput{
        continuation: continuation,
        configuration: configuration,
        starter_cooldowns: input.starter_cooldowns,
        current_cooldowns: current_cooldowns,
        webhook_settings: input.webhook_settings,
        conversation: conversation,
        budget: budget,
        planned_at: planned_at,
        policy: policy,
        no_reply_weight: configuration.conversation_defaults.no_reply_weight
      }

      {:ok,
       %ResponderConversationRunner.Input{
         continuation: continuation_input,
         provider_settings: input.provider_settings,
         turns: input.turns
       }}
    else
      _failure -> {:error, :invalid_responder_conversation_initialization}
    end
  rescue
    _error -> {:error, :invalid_responder_conversation_initialization}
  catch
    _kind, _reason -> {:error, :invalid_responder_conversation_initialization}
  end

  def initialize(_input), do: {:error, :invalid_responder_conversation_initialization}

  defp project_conversation(continuation) do
    waiting = continuation.conversation
    published = continuation.recorded.published.message

    message = %Message{
      conversation_id: published.conversation_id,
      persona_id: published.persona_id,
      origin: published.origin,
      content: published.content,
      discord_message_id: published.discord_message_id,
      inserted_at: published.inserted_at
    }

    conversation = %Conversation{
      id: waiting.id,
      root_event_id: waiting.root_event_id,
      status: waiting.status,
      started_at: waiting.started_at,
      last_message_at: message.inserted_at,
      turn_count: waiting.turn_count,
      llm_call_count: waiting.llm_call_count,
      participants: [message.persona_id],
      messages: [message]
    }

    if ConversationValidator.validate(conversation) == :ok,
      do: {:ok, conversation},
      else: {:error, :invalid_responder_conversation_initialization}
  end

  defp project_cooldowns(continuation, configuration, starter_cooldowns) do
    cooldown = continuation.recorded.cooldown

    current =
      starter_cooldowns
      |> Map.take(Map.keys(configuration.personas.personas))
      |> Map.put(cooldown.persona_id, cooldown)

    if ResponderCandidateProjector.validate_cooldowns(current) == :ok,
      do: {:ok, current},
      else: {:error, :invalid_responder_conversation_initialization}
  end

  defp first_planned_at([%Turn{planned_at: planned_at} | _turns], continuation) do
    completed_at = continuation.recorded.published.attempt.completed_at

    if DateTimeValidator.validate_storage_utc(planned_at) == :ok and
         DateTime.compare(planned_at, completed_at) in [:eq, :gt],
       do: {:ok, planned_at},
       else: {:error, :invalid_responder_conversation_initialization}
  end

  defp first_planned_at(_turns, _continuation),
    do: {:error, :invalid_responder_conversation_initialization}

  defp validate_provider_settings(%ProviderSettings{} = settings, configuration) do
    llm = configuration.llm

    if ProviderSettings.validate(settings) == :ok and settings.provider === llm.provider and
         settings.timeout_ms === llm.timeout_ms and
         settings.max_output_tokens === llm.max_output_tokens and
         settings.reasoning_effort === llm.reasoning_effort,
       do: :ok,
       else: {:error, :invalid_responder_conversation_initialization}
  end

  defp validate_provider_settings(_settings, _configuration),
    do: {:error, :invalid_responder_conversation_initialization}

  defp exact_input?(input),
    do: map_size(input) == @input_key_count and Enum.all?(@input_keys, &Map.has_key?(input, &1))
end

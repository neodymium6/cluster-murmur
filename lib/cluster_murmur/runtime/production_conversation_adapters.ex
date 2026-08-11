defmodule ClusterMurmur.Runtime.ProductionConversationAdapters do
  @moduledoc """
  Builds the fixed persistence and policy adapters for live conversations.

  Every module is application-owned and selected here rather than by deployment
  input. Construction validates cross-pipeline correlations without reading
  persistence, sampling randomness, invoking a provider, or publishing.
  """

  alias ClusterMurmur.Discord.WebhookPublisher
  alias ClusterMurmur.Generation.OpenAICompatibleProvider

  alias ClusterMurmur.Persistence.{
    ConversationStore,
    EventTriggerConversationActionStore,
    MessageStore,
    PersonaCooldownStore,
    PublicationAttemptStore
  }

  alias ClusterMurmur.Runtime.{ResponderTurnCycle, SystemRandom}
  alias ClusterMurmur.Triggers.{AuthorizedConversationPipeline, AuthorizedStarterPipeline}

  @doc "Builds one validated, inspect-redacted production conversation adapter set."
  @spec build() ::
          {:ok, AuthorizedConversationPipeline.Adapters.t()}
          | {:error, :invalid_production_conversation_adapters}
  def build do
    starter = %AuthorizedStarterPipeline.Adapters{
      conversation_action_store: EventTriggerConversationActionStore,
      provider: OpenAICompatibleProvider,
      message_store: MessageStore,
      publication_start_store: PublicationAttemptStore,
      publisher: WebhookPublisher,
      publication_terminal_store: PublicationAttemptStore,
      cooldown_store: PersonaCooldownStore,
      conversation_store: ConversationStore,
      starter_random: SystemRandom,
      reply_random: SystemRandom
    }

    responder = %ResponderTurnCycle.Adapters{
      random: SystemRandom,
      conversation_store: ConversationStore,
      provider: OpenAICompatibleProvider,
      message_store: MessageStore,
      publication_start_store: PublicationAttemptStore,
      publisher: WebhookPublisher,
      publication_terminal_store: PublicationAttemptStore,
      cooldown_store: PersonaCooldownStore
    }

    adapters = %AuthorizedConversationPipeline.Adapters{starter: starter, responder: responder}

    case AuthorizedConversationPipeline.validate_adapters(adapters) do
      :ok ->
        {:ok, adapters}

      {:error, :invalid_authorized_conversation_pipeline} ->
        {:error, :invalid_production_conversation_adapters}
    end
  rescue
    _error -> {:error, :invalid_production_conversation_adapters}
  catch
    _kind, _reason -> {:error, :invalid_production_conversation_adapters}
  end
end

defmodule ClusterMurmur.Runtime.ProductionConversationAdaptersTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.WebhookPublisher
  alias ClusterMurmur.Generation.OpenAICompatibleProvider

  alias ClusterMurmur.Persistence.{
    ConversationStore,
    EventTriggerConversationActionStore,
    MessageStore,
    PersonaCooldownStore,
    PublicationAttemptStore
  }

  alias ClusterMurmur.Runtime.{ProductionConversationAdapters, ResponderTurnCycle, SystemRandom}
  alias ClusterMurmur.Triggers.{AuthorizedConversationPipeline, AuthorizedStarterPipeline}

  defmodule AlternateProvider do
    @moduledoc false
    def generate(_prompt, _settings, _transport), do: {:error, :not_called}
  end

  test "builds the fixed correlated production adapter set" do
    assert {:ok,
            %AuthorizedConversationPipeline.Adapters{
              starter: %AuthorizedStarterPipeline.Adapters{} = starter,
              responder: %ResponderTurnCycle.Adapters{} = responder
            } = adapters} = ProductionConversationAdapters.build()

    assert starter.conversation_action_store == EventTriggerConversationActionStore
    assert starter.provider == OpenAICompatibleProvider
    assert starter.message_store == MessageStore
    assert starter.publication_start_store == PublicationAttemptStore
    assert starter.publisher == WebhookPublisher
    assert starter.publication_terminal_store == PublicationAttemptStore
    assert starter.cooldown_store == PersonaCooldownStore
    assert starter.conversation_store == ConversationStore
    assert starter.starter_random == SystemRandom
    assert starter.reply_random == SystemRandom

    assert responder.random == SystemRandom
    assert responder.conversation_store == ConversationStore
    assert responder.provider == OpenAICompatibleProvider
    assert responder.message_store == MessageStore
    assert responder.publication_start_store == PublicationAttemptStore
    assert responder.publisher == WebhookPublisher
    assert responder.publication_terminal_store == PublicationAttemptStore
    assert responder.cooldown_store == PersonaCooldownStore

    assert AuthorizedStarterPipeline.validate_adapters(starter) == :ok
    assert ResponderTurnCycle.validate_adapters(responder) == :ok
    assert AuthorizedConversationPipeline.validate_adapters(adapters) == :ok

    assert inspect(adapters) ==
             "#ClusterMurmur.Triggers.AuthorizedConversationPipeline.Adapters<...>"
  end

  test "standalone validators reject forged and decorrelated adapter values" do
    assert {:ok, adapters} = ProductionConversationAdapters.build()

    invalid_starter = Map.put(adapters.starter, :private, true)
    decorrelated = %{adapters | responder: %{adapters.responder | provider: AlternateProvider}}

    assert AuthorizedStarterPipeline.validate_adapters(invalid_starter) ==
             {:error, :invalid_starter_pipeline}

    assert ResponderTurnCycle.validate_adapters(decorrelated.responder) == :ok

    assert AuthorizedConversationPipeline.validate_adapters(decorrelated) ==
             {:error, :invalid_authorized_conversation_pipeline}

    assert AuthorizedConversationPipeline.validate_adapters(Map.put(adapters, :private, true)) ==
             {:error, :invalid_authorized_conversation_pipeline}
  end
end

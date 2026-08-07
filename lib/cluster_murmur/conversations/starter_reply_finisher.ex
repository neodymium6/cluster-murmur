defmodule ClusterMurmur.Conversations.StarterReplyFinisher do
  @moduledoc """
  Applies the configured reply gate after one published starter.

  An explicit no-reply decision closes the exact advanced conversation through
  an injected narrow store at the durable publication completion instant. A
  reply decision remains explicit for later bounded responder orchestration and
  performs no storage mutation.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Conversations.{ReplyGate, ReplyGateDecision}
  alias ClusterMurmur.Discord.WebhookSettings

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    ConversationStore
  }

  alias ClusterMurmur.Personas.StarterCooldownRecorder
  alias ClusterMurmur.Personas.StarterCooldownRecorder.Recorded

  defmodule Completed do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:recorded, :decision, :conversation]
    defstruct [:recorded, :decision, :conversation]

    @type t :: %__MODULE__{
            recorded: ClusterMurmur.Personas.StarterCooldownRecorder.Recorded.t(),
            decision: ClusterMurmur.Conversations.ReplyGateDecision.t(),
            conversation: ClusterMurmur.Persistence.ConversationRecord.t()
          }
  end

  @completed_keys Completed.__struct__() |> Map.keys()
  @completed_key_count length(@completed_keys)

  @type error ::
          :conversation_conflict
          | :invalid_conversation_record
          | :invalid_datetime
          | :invalid_event_group
          | :invalid_message_record
          | :invalid_random_source
          | :invalid_random_value
          | :invalid_starter_completion
          | :storage_unavailable

  @type result :: {:ok, Completed.t()} | {:continue, :reply} | {:error, error()}

  @doc "Closes an exact starter conversation only after an explicit no reply."
  @spec finish(term(), term(), term(), term(), module(), module()) :: result()
  def finish(recorded, configuration, cooldowns, settings, random, store \\ ConversationStore)

  def finish(
        %Recorded{} = recorded,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings,
        random,
        store
      )
      when is_atom(random) and is_atom(store) do
    with :ok <- StarterCooldownRecorder.validate(recorded, configuration, cooldowns, settings),
         {:ok, group} <- resolve_group(recorded, configuration),
         {:ok, %ReplyGateDecision{} = decision} <- ReplyGate.evaluate(group, random) do
      apply_decision(decision, recorded, configuration, cooldowns, settings, store)
    else
      {:error, reason}
      when reason in [
             :invalid_event_group,
             :invalid_random_source,
             :invalid_random_value
           ] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_starter_completion}
    end
  rescue
    _error -> {:error, :invalid_starter_completion}
  catch
    _kind, _reason -> {:error, :invalid_starter_completion}
  end

  def finish(_recorded, _configuration, _cooldowns, _settings, _random, _store),
    do: {:error, :invalid_starter_completion}

  @doc "Revalidates one exact explicit no-reply completion capability."
  @spec validate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_starter_completion}
  def validate(
        %Completed{} = completed,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings
      ) do
    if exact_completed?(completed) and
         completed.decision === %ReplyGateDecision{outcome: :no_reply} and
         StarterCooldownRecorder.validate(completed.recorded, configuration, cooldowns, settings) ==
           :ok and
         compatible_current_no_reply?(completed.recorded, configuration) and
         correlated_terminal?(completed) do
      :ok
    else
      {:error, :invalid_starter_completion}
    end
  rescue
    _error -> {:error, :invalid_starter_completion}
  catch
    _kind, _reason -> {:error, :invalid_starter_completion}
  end

  def validate(_completed, _configuration, _cooldowns, _settings),
    do: {:error, :invalid_starter_completion}

  defp apply_decision(
         %ReplyGateDecision{outcome: :reply},
         _recorded,
         _configuration,
         _cooldowns,
         _settings,
         _store
       ),
       do: {:continue, :reply}

  defp apply_decision(
         %ReplyGateDecision{outcome: :no_reply} = decision,
         recorded,
         configuration,
         cooldowns,
         settings,
         store
       ) do
    conversation = recorded.published.started.plan.persisted.conversation
    completed_at = recorded.published.attempt.completed_at

    with :ok <- validate_store(store),
         {:ok, %ConversationRecord{} = terminal} <-
           safe_complete(store, conversation, completed_at),
         :ok <- validate_terminal_result(terminal, conversation, completed_at),
         completed = %Completed{
           recorded: recorded,
           decision: decision,
           conversation: terminal
         },
         :ok <- validate(completed, configuration, cooldowns, settings) do
      {:ok, completed}
    else
      {:error, reason}
      when reason in [
             :conversation_conflict,
             :invalid_conversation_record,
             :invalid_datetime,
             :invalid_message_record,
             :storage_unavailable
           ] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_starter_completion}
    end
  end

  defp apply_decision(_decision, _recorded, _configuration, _cooldowns, _settings, _store),
    do: {:error, :invalid_starter_completion}

  defp resolve_group(recorded, configuration) do
    binding = recorded.published.started.plan.persisted.generated.plan.started.plan.binding

    case Map.fetch(configuration.event_groups.groups, binding.group) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, :invalid_event_group}
    end
  end

  defp compatible_current_no_reply?(recorded, configuration) do
    case resolve_group(recorded, configuration) do
      {:ok, %{reply_probability: probability}} -> probability != 1
      _failure -> false
    end
  end

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :complete, 2),
      do: :ok,
      else: {:error, :storage_unavailable}
  end

  defp safe_complete(store, conversation, completed_at) do
    store.complete(conversation, completed_at)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp validate_terminal_result(terminal, active, completed_at) do
    expected = %{active | status: :completed, completed_at: completed_at}

    if ConversationRecordValidator.validate(terminal) == :ok and terminal === expected,
      do: :ok,
      else: {:error, :invalid_conversation_record}
  end

  defp correlated_terminal?(completed) do
    active = completed.recorded.published.started.plan.persisted.conversation
    completed_at = completed.recorded.published.attempt.completed_at
    validate_terminal_result(completed.conversation, active, completed_at) == :ok
  end

  defp exact_completed?(completed) do
    map_size(completed) == @completed_key_count and
      Enum.all?(@completed_keys, &Map.has_key?(completed, &1))
  end
end

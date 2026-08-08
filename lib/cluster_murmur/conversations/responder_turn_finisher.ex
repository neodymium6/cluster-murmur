defmodule ClusterMurmur.Conversations.ResponderTurnFinisher do
  @moduledoc """
  Finishes one proven published responder turn within bounded conversation state.

  The boundary rebuilds the exact runtime conversation from the persisted
  responder delivery, incorporates the proven cooldown, and evaluates the
  immutable conversation budget at the durable publication completion instant.
  It either returns the exact conversation to waiting or closes it. It performs
  no selection, generation, publication, or external request.
  """

  alias ClusterMurmur.Config.Configuration

  alias ClusterMurmur.Conversations.{
    BudgetEvaluator,
    BudgetState,
    MessageWindow,
    Validator
  }

  alias ClusterMurmur.Discord.WebhookSettings
  alias ClusterMurmur.Messages.Message

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationRecordValidator,
    ConversationStore
  }

  alias ClusterMurmur.Personas.{ResponderCandidateProjector, ResponderCooldownRecorder}
  alias ClusterMurmur.Personas.ResponderCooldownRecorder.Recorded

  defmodule Completed do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:recorded, :budget_state, :conversation, :runtime, :current_cooldowns]
    defstruct [:recorded, :budget_state, :conversation, :runtime, :current_cooldowns]

    @type t :: %__MODULE__{
            recorded: ClusterMurmur.Personas.ResponderCooldownRecorder.Recorded.t(),
            budget_state: ClusterMurmur.Conversations.BudgetState.t(),
            conversation: ClusterMurmur.Persistence.ConversationRecord.t(),
            runtime: ClusterMurmur.Conversations.Conversation.t(),
            current_cooldowns: map()
          }
  end

  defmodule Continuation do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:recorded, :budget_state, :conversation, :runtime, :current_cooldowns]
    defstruct [:recorded, :budget_state, :conversation, :runtime, :current_cooldowns]

    @type t :: %__MODULE__{
            recorded: ClusterMurmur.Personas.ResponderCooldownRecorder.Recorded.t(),
            budget_state: ClusterMurmur.Conversations.BudgetState.t(),
            conversation: ClusterMurmur.Persistence.ConversationRecord.t(),
            runtime: ClusterMurmur.Conversations.Conversation.t(),
            current_cooldowns: map()
          }
  end

  @completed_keys Completed.__struct__() |> Map.keys()
  @completed_key_count length(@completed_keys)
  @continuation_keys Continuation.__struct__() |> Map.keys()
  @continuation_key_count length(@continuation_keys)

  @type error ::
          :conversation_conflict
          | :invalid_conversation_record
          | :invalid_datetime
          | :invalid_message_record
          | :invalid_responder_turn_completion
          | :storage_unavailable

  @type result ::
          {:ok, Completed.t()}
          | {:continue, Continuation.t()}
          | {:error, error()}

  @doc "Waits or completes one exact responder turn after proven publication."
  @spec finish(term(), term(), term(), term(), module()) :: result()
  def finish(recorded, configuration, selection_cooldowns, settings, store \\ ConversationStore)

  def finish(
        %Recorded{} = recorded,
        %Configuration{} = configuration,
        selection_cooldowns,
        %WebhookSettings{} = settings,
        store
      )
      when is_atom(store) do
    with :ok <- validate_store(store),
         :ok <-
           ResponderCooldownRecorder.validate(
             recorded,
             configuration,
             selection_cooldowns,
             settings
           ),
         {:ok, runtime, current_cooldowns, %BudgetState{} = budget_state} <-
           project(recorded, configuration, selection_cooldowns) do
      apply_budget(
        budget_state,
        recorded,
        runtime,
        current_cooldowns,
        configuration,
        selection_cooldowns,
        settings,
        store
      )
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
        {:error, :invalid_responder_turn_completion}
    end
  rescue
    _error -> {:error, :invalid_responder_turn_completion}
  catch
    _kind, _reason -> {:error, :invalid_responder_turn_completion}
  end

  def finish(_recorded, _configuration, _selection_cooldowns, _settings, _store),
    do: {:error, :invalid_responder_turn_completion}

  @doc "Revalidates one exact budget-exhausted responder completion capability."
  @spec validate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_responder_turn_completion}
  def validate(
        %Completed{} = completed,
        %Configuration{} = configuration,
        selection_cooldowns,
        %WebhookSettings{} = settings
      ) do
    with true <- exact_completed?(completed),
         :ok <-
           ResponderCooldownRecorder.validate(
             completed.recorded,
             configuration,
             selection_cooldowns,
             settings
           ),
         {:ok, runtime, current_cooldowns, budget_state} <-
           project(completed.recorded, configuration, selection_cooldowns),
         false <- budget_state.open?,
         :ok <-
           validate_terminal(
             completed.conversation,
             active_record(completed.recorded),
             completion_instant(completed.recorded)
           ),
         true <- completed.runtime === %{runtime | status: :completed},
         true <- completed.current_cooldowns === current_cooldowns,
         true <- completed.budget_state === budget_state do
      :ok
    else
      _failure -> {:error, :invalid_responder_turn_completion}
    end
  rescue
    _error -> {:error, :invalid_responder_turn_completion}
  catch
    _kind, _reason -> {:error, :invalid_responder_turn_completion}
  end

  def validate(_completed, _configuration, _selection_cooldowns, _settings),
    do: {:error, :invalid_responder_turn_completion}

  @doc "Revalidates one exact waiting responder continuation capability."
  @spec validate_continuation(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_responder_turn_completion}
  def validate_continuation(
        %Continuation{} = continuation,
        %Configuration{} = configuration,
        selection_cooldowns,
        %WebhookSettings{} = settings
      ) do
    with true <- exact_continuation?(continuation),
         :ok <-
           ResponderCooldownRecorder.validate(
             continuation.recorded,
             configuration,
             selection_cooldowns,
             settings
           ),
         {:ok, runtime, current_cooldowns, budget_state} <-
           project(continuation.recorded, configuration, selection_cooldowns),
         true <- budget_state.open?,
         :ok <- validate_waiting(continuation.conversation, active_record(continuation.recorded)),
         true <- continuation.runtime === %{runtime | status: :waiting},
         true <- continuation.current_cooldowns === current_cooldowns,
         true <- continuation.budget_state === budget_state do
      :ok
    else
      _failure -> {:error, :invalid_responder_turn_completion}
    end
  rescue
    _error -> {:error, :invalid_responder_turn_completion}
  catch
    _kind, _reason -> {:error, :invalid_responder_turn_completion}
  end

  def validate_continuation(_continuation, _configuration, _selection_cooldowns, _settings),
    do: {:error, :invalid_responder_turn_completion}

  defp project(recorded, configuration, selection_cooldowns) do
    with {:ok, runtime} <- project_runtime(recorded),
         {:ok, current_cooldowns} <-
           project_cooldowns(recorded, configuration, selection_cooldowns),
         {:ok, budget_state} <-
           BudgetEvaluator.evaluate(
             runtime,
             recorded.published.started.plan.delivery.plan.input.budget,
             completion_instant(recorded)
           ) do
      {:ok, runtime, current_cooldowns, budget_state}
    else
      _failure -> {:error, :invalid_responder_turn_completion}
    end
  end

  defp project_runtime(recorded) do
    input = recorded.published.started.plan.delivery.plan.input
    before = input.conversation
    active = active_record(recorded)
    published = recorded.published.message

    message = %Message{
      conversation_id: published.conversation_id,
      persona_id: published.persona_id,
      origin: published.origin,
      content: published.content,
      discord_message_id: published.discord_message_id,
      inserted_at: published.inserted_at
    }

    participants = append_participant(before.participants, published.persona_id)

    with {:ok, messages} <- MessageWindow.append(before.messages, message) do
      runtime = %{
        before
        | status: :generating,
          last_message_at: published.inserted_at,
          turn_count: active.turn_count,
          llm_call_count: active.llm_call_count,
          participants: participants,
          messages: messages
      }

      if Validator.validate(runtime) == :ok and correlate_runtime_record?(runtime, active),
        do: {:ok, runtime},
        else: {:error, :invalid_responder_turn_completion}
    else
      _failure -> {:error, :invalid_responder_turn_completion}
    end
  end

  defp project_cooldowns(recorded, configuration, selection_cooldowns) do
    cooldown = recorded.cooldown

    current =
      selection_cooldowns
      |> Map.take(Map.keys(configuration.personas.personas))
      |> Map.put(cooldown.persona_id, cooldown)

    if ResponderCandidateProjector.validate_cooldowns(current) == :ok,
      do: {:ok, current},
      else: {:error, :invalid_responder_turn_completion}
  rescue
    _error -> {:error, :invalid_responder_turn_completion}
  end

  defp apply_budget(
         %BudgetState{open?: true} = budget_state,
         recorded,
         runtime,
         current_cooldowns,
         configuration,
         selection_cooldowns,
         settings,
         store
       ) do
    active = active_record(recorded)

    with {:ok, %ConversationRecord{} = waiting} <- safe_wait(store, active),
         :ok <- validate_waiting(waiting, active),
         continuation = %Continuation{
           recorded: recorded,
           budget_state: budget_state,
           conversation: waiting,
           runtime: %{runtime | status: :waiting},
           current_cooldowns: current_cooldowns
         },
         :ok <-
           validate_continuation(
             continuation,
             configuration,
             selection_cooldowns,
             settings
           ) do
      {:continue, continuation}
    else
      {:error, reason} -> store_error(reason)
      _failure -> {:error, :invalid_responder_turn_completion}
    end
  end

  defp apply_budget(
         %BudgetState{open?: false} = budget_state,
         recorded,
         runtime,
         current_cooldowns,
         configuration,
         selection_cooldowns,
         settings,
         store
       ) do
    active = active_record(recorded)
    completed_at = completion_instant(recorded)

    with {:ok, %ConversationRecord{} = terminal} <-
           safe_complete(store, active, completed_at),
         :ok <- validate_terminal(terminal, active, completed_at),
         completed = %Completed{
           recorded: recorded,
           budget_state: budget_state,
           conversation: terminal,
           runtime: %{runtime | status: :completed},
           current_cooldowns: current_cooldowns
         },
         :ok <- validate(completed, configuration, selection_cooldowns, settings) do
      {:ok, completed}
    else
      {:error, reason} -> store_error(reason)
      _failure -> {:error, :invalid_responder_turn_completion}
    end
  end

  defp active_record(recorded), do: recorded.published.started.plan.delivery.conversation
  defp completion_instant(recorded), do: recorded.published.attempt.completed_at

  defp append_participant(participants, persona_id) do
    if persona_id in participants, do: participants, else: participants ++ [persona_id]
  end

  defp correlate_runtime_record?(runtime, record) do
    runtime.id === record.id and runtime.root_event_id === record.root_event_id and
      runtime.status === record.status and runtime.started_at === record.started_at and
      runtime.turn_count === record.turn_count and
      runtime.llm_call_count === record.llm_call_count
  end

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :wait, 1) and
         function_exported?(store, :complete, 2),
       do: :ok,
       else: {:error, :storage_unavailable}
  end

  defp safe_wait(store, active) do
    store.wait(active)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp safe_complete(store, active, completed_at) do
    store.complete(active, completed_at)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp validate_waiting(waiting, active) do
    expected = %{active | status: :waiting}

    if ConversationRecordValidator.validate_active(waiting) == :ok and waiting === expected,
      do: :ok,
      else: {:error, :invalid_conversation_record}
  end

  defp validate_terminal(terminal, active, completed_at) do
    expected = %{active | status: :completed, completed_at: completed_at}

    if ConversationRecordValidator.validate(terminal) == :ok and terminal === expected,
      do: :ok,
      else: {:error, :invalid_conversation_record}
  end

  defp store_error(reason)
       when reason in [
              :conversation_conflict,
              :invalid_conversation_record,
              :invalid_datetime,
              :invalid_message_record,
              :storage_unavailable
            ],
       do: {:error, reason}

  defp store_error(_reason), do: {:error, :invalid_responder_turn_completion}

  defp exact_completed?(completed) do
    map_size(completed) == @completed_key_count and
      Enum.all?(@completed_keys, &Map.has_key?(completed, &1))
  end

  defp exact_continuation?(continuation) do
    map_size(continuation) == @continuation_key_count and
      Enum.all?(@continuation_keys, &Map.has_key?(continuation, &1))
  end
end

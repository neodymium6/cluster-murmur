defmodule ClusterMurmur.Triggers.EventTriggerConversationPlanner do
  @moduledoc """
  Plans one authorized event trigger's conversation start without side effects.

  The planner revalidates the durable trigger authorization against one complete
  runtime configuration, resolves its exact binding, projects currently eligible
  starter candidates from a supplied cooldown snapshot, and delegates only the
  final weighted choice to an injected random source. The result contains one
  pristine conversation value for later atomic action execution.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Conversations.Conversation
  alias ClusterMurmur.Conversations.Validator, as: ConversationValidator
  alias ClusterMurmur.Personas.{Binding, Persona, StarterCandidateProjector, StarterSelector}
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:authorization, :binding, :starter, :conversation]
    defstruct [:authorization, :binding, :starter, :conversation]

    @type t :: %__MODULE__{
            authorization: ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization.t(),
            binding: ClusterMurmur.Personas.Binding.t(),
            starter: ClusterMurmur.Personas.Persona.t(),
            conversation: ClusterMurmur.Conversations.Conversation.t()
          }
  end

  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error ::
          :invalid_authorization
          | :invalid_configuration
          | :invalid_conversation
          | :invalid_conversation_plan
          | :invalid_starter_projection
          | :invalid_starter_selection

  @doc "Plans one pristine conversation and selected starter from an authorization."
  @spec plan(term(), term(), term(), term(), term()) ::
          {:ok, Plan.t()} | {:skip, :no_starter} | {:error, error()}
  def plan(authorization, configuration, cooldowns, conversation_id, random) do
    with :ok <- validate_authorization(authorization),
         :ok <- validate_configuration(configuration),
         {:ok, binding} <- resolve_binding(authorization, configuration),
         {:ok, conversation} <- build_conversation(authorization, conversation_id),
         {:ok, candidates} <-
           project_starters(
             binding,
             configuration,
             cooldowns,
             authorization.plan.executed_at
           ),
         {:ok, starter_id} <- select_starter(candidates, random),
         {:ok, starter} <- resolve_starter(starter_id, configuration),
         result = %Plan{
           authorization: authorization,
           binding: binding,
           starter: starter,
           conversation: conversation
         },
         :ok <- validate_plan(result, configuration, cooldowns) do
      {:ok, result}
    else
      :none -> {:skip, :no_starter}
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_conversation_plan}
    end
  rescue
    _error -> {:error, :invalid_conversation_plan}
  catch
    _kind, _reason -> {:error, :invalid_conversation_plan}
  end

  @doc "Revalidates one exact plan against configuration and cooldown facts."
  @spec validate_plan(term(), term(), term()) ::
          :ok | {:error, :invalid_conversation_plan}
  def validate_plan(%Plan{} = plan, configuration, cooldowns) do
    with true <- exact_plan?(plan),
         :ok <- validate_authorization(plan.authorization),
         :ok <- validate_configuration(configuration),
         {:ok, binding} <- resolve_binding(plan.authorization, configuration),
         true <- plan.binding === binding,
         {:ok, configured_starter} <-
           resolve_starter(plan.starter.id, configuration),
         true <- plan.starter === configured_starter,
         :ok <- validate_conversation(plan.conversation, plan.authorization),
         {:ok, candidates} <-
           project_starters(
             binding,
             configuration,
             cooldowns,
             plan.authorization.plan.executed_at
           ),
         true <- eligible_starter?(candidates, plan.starter.id) do
      :ok
    else
      _failure -> {:error, :invalid_conversation_plan}
    end
  rescue
    _error -> {:error, :invalid_conversation_plan}
  catch
    _kind, _reason -> {:error, :invalid_conversation_plan}
  end

  def validate_plan(_plan, _configuration, _cooldowns),
    do: {:error, :invalid_conversation_plan}

  defp validate_authorization(%Authorization{} = authorization) do
    case EventTriggerAuthorizer.validate(authorization) do
      :ok -> :ok
      {:error, :invalid_authorization} -> {:error, :invalid_authorization}
    end
  end

  defp validate_authorization(_authorization), do: {:error, :invalid_authorization}

  defp validate_configuration(%Configuration{} = configuration) do
    case Configuration.validate(configuration) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_configuration}
    end
  end

  defp validate_configuration(_configuration), do: {:error, :invalid_configuration}

  defp resolve_binding(authorization, configuration) do
    trigger = authorization.plan.trigger

    case Map.fetch(configuration.triggers.triggers, trigger.id) do
      {:ok, configured_trigger} when configured_trigger === trigger ->
        fetch_binding(configuration, trigger.binding)

      {:ok, _different_trigger} ->
        {:error, :invalid_authorization}

      :error ->
        {:error, :invalid_authorization}
    end
  end

  defp fetch_binding(configuration, binding_id) do
    case Map.fetch(configuration.bindings.bindings, binding_id) do
      {:ok, %Binding{} = binding} -> {:ok, binding}
      _failure -> {:error, :invalid_configuration}
    end
  end

  defp build_conversation(authorization, conversation_id) do
    conversation = %Conversation{
      id: conversation_id,
      root_event_id: authorization.plan.event.id,
      status: :starting,
      started_at: authorization.plan.executed_at,
      last_message_at: nil,
      turn_count: 0,
      llm_call_count: 0,
      participants: [],
      messages: []
    }

    case ConversationValidator.validate(conversation) do
      :ok -> {:ok, conversation}
      {:error, :invalid_conversation} -> {:error, :invalid_conversation}
    end
  end

  defp project_starters(binding, configuration, cooldowns, executed_at) do
    case StarterCandidateProjector.project(
           binding,
           configuration.personas.personas,
           cooldowns,
           executed_at
         ) do
      {:ok, candidates} -> {:ok, candidates}
      {:error, _reason} -> {:error, :invalid_starter_projection}
    end
  end

  defp select_starter(candidates, random) do
    case StarterSelector.select(candidates, random) do
      {:ok, starter_id} -> {:ok, starter_id}
      :none -> :none
      {:error, _reason} -> {:error, :invalid_starter_selection}
    end
  end

  defp resolve_starter(starter_id, configuration) do
    case Map.fetch(configuration.personas.personas, starter_id) do
      {:ok, %Persona{} = starter} -> {:ok, starter}
      _failure -> {:error, :invalid_configuration}
    end
  end

  defp validate_conversation(conversation, authorization) do
    if ConversationValidator.validate(conversation) == :ok and
         conversation.root_event_id === authorization.plan.event.id and
         conversation.status === :starting and
         same_datetime?(conversation.started_at, authorization.plan.executed_at) and
         conversation.last_message_at === nil and conversation.turn_count === 0 and
         conversation.llm_call_count === 0 and conversation.participants === [] and
         conversation.messages === [] do
      :ok
    else
      {:error, :invalid_conversation_plan}
    end
  end

  defp eligible_starter?(candidates, starter_id),
    do: Enum.any?(candidates, &(&1.persona_id === starter_id and &1.weight > 0))

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false
end

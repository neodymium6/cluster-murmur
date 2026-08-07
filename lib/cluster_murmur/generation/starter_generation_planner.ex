defmodule ClusterMurmur.Generation.StarterGenerationPlanner do
  @moduledoc """
  Plans the first generation request for one durably started conversation.

  The planner revalidates the exact one-use conversation-start capability,
  projects only the selected persona's display identity and instructions plus
  allowlisted event facts, and assembles one provider-neutral structured prompt.
  It makes no provider call and does not persist a message.
  """

  alias ClusterMurmur.Config.Configuration

  alias ClusterMurmur.Generation.{
    Context,
    ContextValidator,
    CreativeContext,
    FactProjector,
    PersonaProjection,
    PersonaProjectionValidator,
    PromptAssembler,
    PromptRequest
  }

  alias ClusterMurmur.Triggers.EventTriggerConversationStarter
  alias ClusterMurmur.Triggers.EventTriggerConversationStarter.Started

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:started, :context, :request]
    defstruct [:started, :context, :request]

    @type t :: %__MODULE__{
            started: ClusterMurmur.Triggers.EventTriggerConversationStarter.Started.t(),
            context: ClusterMurmur.Generation.Context.t(),
            request: ClusterMurmur.Generation.PromptRequest.t()
          }
  end

  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error :: :invalid_starter_generation

  @doc "Builds one exact provider-neutral request for the selected starter."
  @spec plan(term(), term(), term()) :: {:ok, Plan.t()} | {:error, error()}
  def plan(%Started{} = started, %Configuration{} = configuration, cooldowns) do
    with :ok <- EventTriggerConversationStarter.validate(started, configuration, cooldowns),
         {:ok, context} <- build_context(started),
         {:ok, %PromptRequest{} = request} <- PromptAssembler.assemble(context),
         result = %Plan{started: started, context: context, request: request},
         :ok <- validate(result, configuration, cooldowns) do
      {:ok, result}
    else
      _failure -> {:error, :invalid_starter_generation}
    end
  rescue
    _error -> {:error, :invalid_starter_generation}
  catch
    _kind, _reason -> {:error, :invalid_starter_generation}
  end

  def plan(_started, _configuration, _cooldowns),
    do: {:error, :invalid_starter_generation}

  @doc "Revalidates one exact starter-generation plan and deterministic projection."
  @spec validate(term(), term(), term()) :: :ok | {:error, error()}
  def validate(%Plan{} = plan, %Configuration{} = configuration, cooldowns) do
    with true <- exact_plan?(plan),
         :ok <- EventTriggerConversationStarter.validate(plan.started, configuration, cooldowns),
         {:ok, expected_context} <- build_context(plan.started),
         true <- plan.context === expected_context,
         {:ok, expected_request} <- PromptAssembler.assemble(expected_context),
         true <- plan.request === expected_request do
      :ok
    else
      _failure -> {:error, :invalid_starter_generation}
    end
  rescue
    _error -> {:error, :invalid_starter_generation}
  catch
    _kind, _reason -> {:error, :invalid_starter_generation}
  end

  def validate(_plan, _configuration, _cooldowns),
    do: {:error, :invalid_starter_generation}

  defp build_context(started) do
    event = started.plan.authorization.plan.event
    starter = started.plan.starter

    persona = %PersonaProjection{
      display_name: starter.display_name,
      instructions: starter.prompt
    }

    context = %Context{
      persona: persona,
      facts: nil,
      creative_context: %CreativeContext{
        conversation_kind: started.plan.binding.group,
        mood: "attentive"
      },
      conversation: []
    }

    with :ok <- PersonaProjectionValidator.validate(persona),
         {:ok, facts} <- FactProjector.project(event),
         context = %{context | facts: facts},
         :ok <- ContextValidator.validate(context) do
      {:ok, context}
    else
      _failure -> {:error, :invalid_starter_generation}
    end
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end
end

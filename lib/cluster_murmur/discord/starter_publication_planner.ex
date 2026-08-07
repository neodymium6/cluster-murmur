defmodule ClusterMurmur.Discord.StarterPublicationPlanner do
  @moduledoc """
  Plans publication for one durably persisted starter message.

  The planner revalidates the complete persisted starter capability, resolves
  its exact selected persona from current configuration, and delegates payload
  construction to the fixed Discord publication planner. It performs no
  external call or storage mutation.
  """

  alias ClusterMurmur.Config.Configuration

  alias ClusterMurmur.Discord.{
    PublicationPlanner,
    PublicationPlanValidator,
    WebhookSettings
  }

  alias ClusterMurmur.Discord.PublicationPlanner.Plan, as: PublicationPlan
  alias ClusterMurmur.Generation.StarterMessagePersister
  alias ClusterMurmur.Generation.StarterMessagePersister.Persisted
  alias ClusterMurmur.Personas.Persona

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:persisted, :publication]
    defstruct [:persisted, :publication]

    @type t :: %__MODULE__{
            persisted: ClusterMurmur.Generation.StarterMessagePersister.Persisted.t(),
            publication: ClusterMurmur.Discord.PublicationPlanner.Plan.t()
          }
  end

  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error :: :invalid_starter_publication

  @doc "Builds one fixed Discord plan for an exact persisted starter message."
  @spec plan(term(), term(), term(), term()) :: {:ok, Plan.t()} | {:error, error()}
  def plan(
        %Persisted{} = persisted,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings
      ) do
    with :ok <- StarterMessagePersister.validate(persisted, configuration, cooldowns),
         {:ok, %Persona{} = persona} <- resolve_persona(persisted, configuration),
         {:ok, %PublicationPlan{} = publication} <-
           PublicationPlanner.plan(persisted.message, persona, settings),
         :ok <-
           PublicationPlanValidator.validate(
             publication,
             persisted.message,
             persona,
             settings
           ),
         result = %Plan{persisted: persisted, publication: publication},
         :ok <- validate(result, configuration, cooldowns, settings) do
      {:ok, result}
    else
      _failure -> {:error, :invalid_starter_publication}
    end
  rescue
    _error -> {:error, :invalid_starter_publication}
  catch
    _kind, _reason -> {:error, :invalid_starter_publication}
  end

  def plan(_persisted, _configuration, _cooldowns, _settings),
    do: {:error, :invalid_starter_publication}

  @doc "Revalidates one exact starter publication plan against current inputs."
  @spec validate(term(), term(), term(), term()) :: :ok | {:error, error()}
  def validate(
        %Plan{} = plan,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings
      ) do
    with true <- exact_plan?(plan),
         :ok <- StarterMessagePersister.validate(plan.persisted, configuration, cooldowns),
         {:ok, persona} <- resolve_persona(plan.persisted, configuration),
         :ok <-
           PublicationPlanValidator.validate(
             plan.publication,
             plan.persisted.message,
             persona,
             settings
           ) do
      :ok
    else
      _failure -> {:error, :invalid_starter_publication}
    end
  rescue
    _error -> {:error, :invalid_starter_publication}
  catch
    _kind, _reason -> {:error, :invalid_starter_publication}
  end

  def validate(_plan, _configuration, _cooldowns, _settings),
    do: {:error, :invalid_starter_publication}

  defp resolve_persona(persisted, configuration) do
    starter = persisted.generated.plan.started.plan.starter

    case Map.fetch(configuration.personas.personas, persisted.message.persona_id) do
      {:ok, %Persona{} = persona} when persona === starter -> {:ok, persona}
      _failure -> {:error, :invalid_starter_publication}
    end
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end
end

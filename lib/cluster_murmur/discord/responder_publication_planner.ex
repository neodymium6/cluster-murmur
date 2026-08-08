defmodule ClusterMurmur.Discord.ResponderPublicationPlanner do
  @moduledoc """
  Builds one fixed Discord publication plan from a persisted responder delivery.

  The pure boundary revalidates the durable delivery, exact configuration,
  cooldown snapshot, responder, and webhook settings. It performs no storage
  mutation or external request.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer.Delivery

  alias ClusterMurmur.Discord.{
    PublicationPlanner,
    PublicationPlanValidator,
    WebhookSettings
  }

  alias ClusterMurmur.Discord.PublicationPlanner.Plan, as: PublicationPlan
  alias ClusterMurmur.Personas.{Persona, Validator, ResponderCandidateProjector}

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:delivery, :publication]
    defstruct [:delivery, :publication]

    @type t :: %__MODULE__{
            delivery: ClusterMurmur.Conversations.ResponderContinuationConsumer.Delivery.t(),
            publication: ClusterMurmur.Discord.PublicationPlanner.Plan.t()
          }
  end

  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error :: :invalid_responder_publication

  @doc "Plans a fixed Discord request for one exact persisted responder message."
  @spec plan(term(), term(), term(), term()) :: {:ok, Plan.t()} | {:error, error()}
  def plan(
        %Delivery{} = delivery,
        %Configuration{} = configuration,
        current_cooldowns,
        %WebhookSettings{} = settings
      ) do
    with :ok <- validate_inputs(delivery, configuration, current_cooldowns, settings),
         {:ok, persona} <- resolve_persona(delivery, configuration),
         {:ok, %PublicationPlan{} = publication} <-
           PublicationPlanner.plan(delivery.message, persona, settings),
         result = %Plan{delivery: delivery, publication: publication},
         :ok <- validate(result, configuration, current_cooldowns, settings) do
      {:ok, result}
    else
      _failure -> {:error, :invalid_responder_publication}
    end
  rescue
    _error -> {:error, :invalid_responder_publication}
  catch
    _kind, _reason -> {:error, :invalid_responder_publication}
  end

  def plan(_delivery, _configuration, _current_cooldowns, _settings),
    do: {:error, :invalid_responder_publication}

  @doc "Revalidates a fixed responder publication plan against exact current inputs."
  @spec validate(term(), term(), term(), term()) :: :ok | {:error, error()}
  def validate(
        %Plan{} = plan,
        %Configuration{} = configuration,
        current_cooldowns,
        %WebhookSettings{} = settings
      ) do
    with true <- exact_plan?(plan),
         :ok <- validate_inputs(plan.delivery, configuration, current_cooldowns, settings),
         {:ok, persona} <- resolve_persona(plan.delivery, configuration),
         :ok <-
           PublicationPlanValidator.validate(
             plan.publication,
             plan.delivery.message,
             persona,
             settings
           ) do
      :ok
    else
      _failure -> {:error, :invalid_responder_publication}
    end
  rescue
    _error -> {:error, :invalid_responder_publication}
  catch
    _kind, _reason -> {:error, :invalid_responder_publication}
  end

  def validate(_plan, _configuration, _current_cooldowns, _settings),
    do: {:error, :invalid_responder_publication}

  defp validate_inputs(delivery, configuration, current_cooldowns, settings) do
    input = delivery.plan.input

    with :ok <- ResponderContinuationConsumer.validate_delivery(delivery, delivery.plan),
         :ok <- Configuration.validate(configuration),
         :ok <- ResponderCandidateProjector.validate_cooldowns(current_cooldowns),
         :ok <- WebhookSettings.validate(settings),
         true <- input.configuration === configuration,
         true <- input.current_cooldowns === current_cooldowns,
         true <- input.webhook_settings === settings do
      :ok
    else
      _failure -> {:error, :invalid_responder_publication}
    end
  end

  defp resolve_persona(delivery, configuration) do
    selected = delivery.plan.responder

    case Map.fetch(configuration.personas.personas, delivery.message.persona_id) do
      {:ok, %Persona{} = persona} when persona === selected ->
        if Validator.validate(persona) == :ok,
          do: {:ok, persona},
          else: {:error, :invalid_responder_publication}

      _failure ->
        {:error, :invalid_responder_publication}
    end
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end
end

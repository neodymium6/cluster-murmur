defmodule ClusterMurmur.Generation.StarterGenerator do
  @moduledoc """
  Generates one validated unpublished starter message through an injected provider.

  The executor revalidates the complete starter-generation plan and provider
  settings, calls the provider exactly once, normalizes accepted output, and
  falls back deterministically for every provider or output failure. It does not
  persist or publish the resulting message.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Generation.{
    FallbackGenerator,
    ProviderResultResolver,
    ProviderSettings,
    StarterGenerationPlanner
  }

  alias ClusterMurmur.Generation.StarterGenerationPlanner.Plan
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  @discord_content_limit 2_000

  defmodule Generated do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:plan, :message]
    defstruct [:plan, :message]

    @type t :: %__MODULE__{
            plan: ClusterMurmur.Generation.StarterGenerationPlanner.Plan.t(),
            message: ClusterMurmur.Messages.Message.t()
          }
  end

  @generated_keys Generated.__struct__() |> Map.keys()
  @generated_key_count length(@generated_keys)

  @type error ::
          :invalid_datetime
          | :invalid_provider
          | :invalid_provider_settings
          | :invalid_starter_generation
          | :invalid_starter_message

  @doc "Calls one provider and returns an LLM or deterministic fallback message."
  @spec generate(term(), term(), term(), term(), term(), module(), function()) ::
          {:ok, Generated.t()} | {:error, error()}
  def generate(
        %Plan{} = plan,
        %Configuration{} = configuration,
        cooldowns,
        %ProviderSettings{} = settings,
        inserted_at,
        provider,
        transport
      )
      when is_atom(provider) and is_function(transport, 1) do
    with :ok <- StarterGenerationPlanner.validate(plan, configuration, cooldowns),
         :ok <- validate_settings(settings, configuration),
         :ok <- validate_provider(provider),
         :ok <- validate_inserted_at(inserted_at, plan),
         provider_result <- call_provider(provider, plan, settings, transport),
         {:ok, decision} <-
           ProviderResultResolver.resolve(
             provider_result,
             plan.context.persona,
             @discord_content_limit
           ),
         {:ok, message} <- build_message(decision, plan, inserted_at),
         generated = %Generated{plan: plan, message: message},
         :ok <- validate(generated, configuration, cooldowns) do
      {:ok, generated}
    else
      {:error, reason}
      when reason in [
             :invalid_datetime,
             :invalid_provider,
             :invalid_provider_settings,
             :invalid_starter_generation,
             :invalid_starter_message
           ] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_starter_message}
    end
  rescue
    _error -> {:error, :invalid_starter_message}
  catch
    _kind, _reason -> {:error, :invalid_starter_message}
  end

  def generate(_plan, _configuration, _cooldowns, _settings, _at, _provider, _transport),
    do: {:error, :invalid_starter_generation}

  @doc "Revalidates one generated message against its exact starter plan."
  @spec validate(term(), term(), term()) :: :ok | {:error, :invalid_starter_message}
  def validate(%Generated{} = generated, %Configuration{} = configuration, cooldowns) do
    if exact_generated?(generated) and
         StarterGenerationPlanner.validate(generated.plan, configuration, cooldowns) == :ok and
         correlated_message?(generated.message, generated.plan) do
      :ok
    else
      {:error, :invalid_starter_message}
    end
  rescue
    _error -> {:error, :invalid_starter_message}
  catch
    _kind, _reason -> {:error, :invalid_starter_message}
  end

  def validate(_generated, _configuration, _cooldowns),
    do: {:error, :invalid_starter_message}

  defp validate_settings(settings, configuration) do
    llm = configuration.llm

    if ProviderSettings.validate(settings) == :ok and
         settings.provider === llm.provider and settings.timeout_ms === llm.timeout_ms and
         settings.max_output_tokens === llm.max_output_tokens do
      :ok
    else
      {:error, :invalid_provider_settings}
    end
  end

  defp validate_provider(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :generate, 3),
      do: :ok,
      else: {:error, :invalid_provider}
  end

  defp validate_inserted_at(inserted_at, plan) do
    event = plan.started.plan.authorization.plan.event

    if DateTimeValidator.validate_storage_utc(inserted_at) == :ok and
         DateTime.compare(inserted_at, latest_event_at(event)) in [:gt, :eq] and
         DateTime.compare(inserted_at, plan.started.conversation.started_at) in [:gt, :eq] do
      :ok
    else
      {:error, :invalid_datetime}
    end
  end

  defp call_provider(provider, plan, settings, transport) do
    provider.generate(plan.request, settings, transport)
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp build_message({:llm, content}, plan, inserted_at) do
    message = message(plan, :llm, content, inserted_at)

    if MessageValidator.validate(message) == :ok,
      do: {:ok, message},
      else: {:error, :invalid_starter_message}
  end

  defp build_message(:fallback, plan, inserted_at) do
    FallbackGenerator.generate(
      plan.started.plan.authorization.plan.event,
      plan.started.conversation.id,
      plan.started.plan.starter.id,
      inserted_at
    )
    |> normalize_fallback()
  end

  defp normalize_fallback({:ok, %Message{} = message}), do: {:ok, message}
  defp normalize_fallback(_failure), do: {:error, :invalid_starter_message}

  defp message(plan, origin, content, inserted_at) do
    %Message{
      conversation_id: plan.started.conversation.id,
      persona_id: plan.started.plan.starter.id,
      origin: origin,
      content: content,
      discord_message_id: nil,
      inserted_at: inserted_at
    }
  end

  defp correlated_message?(message, plan) do
    MessageValidator.validate(message) == :ok and
      message.conversation_id === plan.started.conversation.id and
      message.persona_id === plan.started.plan.starter.id and
      message.origin in [:llm, :fallback] and is_nil(message.discord_message_id) and
      validate_inserted_at(message.inserted_at, plan) == :ok
  end

  defp latest_event_at(%{observed_at: nil, occurred_at: occurred_at}), do: occurred_at

  defp latest_event_at(%{observed_at: observed_at, occurred_at: occurred_at}) do
    if DateTime.compare(observed_at, occurred_at) == :lt, do: occurred_at, else: observed_at
  end

  defp exact_generated?(generated) do
    map_size(generated) == @generated_key_count and
      Enum.all?(@generated_keys, &Map.has_key?(generated, &1))
  end
end

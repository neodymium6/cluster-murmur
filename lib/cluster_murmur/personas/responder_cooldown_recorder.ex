defmodule ClusterMurmur.Personas.ResponderCooldownRecorder do
  @moduledoc """
  Records the selected persona's cooldown after a proven responder publication.

  Only an exact successful publication capability can cross this boundary. The
  authoritative spoken instant is the durable publication completion instant,
  and the deadline is derived solely from the exact current persona's bounded
  cooldown configuration. The injected store receives no publication content,
  credentials, or transport values.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Discord.{ResponderPublicationExecutor, WebhookSettings}
  alias ClusterMurmur.Discord.ResponderPublicationExecutor.Outcome

  alias ClusterMurmur.Persistence.{
    PersonaCooldownRecord,
    PersonaCooldownRecordValidator,
    PersonaCooldownStore
  }

  alias ClusterMurmur.Personas.{Persona, Validator}

  defmodule Recorded do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:published, :cooldown]
    defstruct [:published, :cooldown]

    @type t :: %__MODULE__{
            published: ClusterMurmur.Discord.ResponderPublicationExecutor.Outcome.t(),
            cooldown: ClusterMurmur.Persistence.PersonaCooldownRecord.t()
          }
  end

  @recorded_keys Recorded.__struct__() |> Map.keys()
  @recorded_key_count length(@recorded_keys)

  @type error ::
          :invalid_persona_cooldown
          | :invalid_persona_cooldown_record
          | :invalid_responder_cooldown
          | :persona_cooldown_conflict
          | :storage_unavailable

  @doc "Records one cooldown from an exact proven responder publication."
  @spec record(term(), term(), term(), term(), module()) ::
          {:ok, Recorded.t()} | {:error, error()}
  def record(published, configuration, cooldowns, settings, store \\ PersonaCooldownStore)

  def record(
        %Outcome{status: :succeeded, error_class: nil} = published,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings,
        store
      )
      when is_atom(store) do
    with :ok <-
           ResponderPublicationExecutor.validate(published, configuration, cooldowns, settings),
         {:ok, persona} <- resolve_persona(published, configuration),
         {:ok, spoken_at, cooldown_until} <- cooldown_facts(published, persona),
         :ok <- validate_store(store),
         {:ok, %PersonaCooldownRecord{} = cooldown} <-
           safe_record(store, persona.id, spoken_at, cooldown_until),
         :ok <- validate_result(cooldown, persona.id, spoken_at, cooldown_until),
         recorded = %Recorded{published: published, cooldown: cooldown},
         :ok <- validate(recorded, configuration, cooldowns, settings) do
      {:ok, recorded}
    else
      {:error, reason}
      when reason in [
             :invalid_persona_cooldown,
             :invalid_persona_cooldown_record,
             :invalid_responder_cooldown,
             :persona_cooldown_conflict,
             :storage_unavailable
           ] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_responder_cooldown}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  def record(_published, _configuration, _cooldowns, _settings, _store),
    do: {:error, :invalid_responder_cooldown}

  @doc "Revalidates one exact recorded cooldown capability."
  @spec validate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_responder_cooldown}
  def validate(
        %Recorded{} = recorded,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings
      ) do
    with true <- exact_recorded?(recorded),
         :ok <-
           ResponderPublicationExecutor.validate(
             recorded.published,
             configuration,
             cooldowns,
             settings
           ),
         true <- recorded.published.status === :succeeded,
         {:ok, persona} <- resolve_persona(recorded.published, configuration),
         {:ok, spoken_at, cooldown_until} <- cooldown_facts(recorded.published, persona),
         :ok <- validate_result(recorded.cooldown, persona.id, spoken_at, cooldown_until) do
      :ok
    else
      _failure -> {:error, :invalid_responder_cooldown}
    end
  rescue
    _error -> {:error, :invalid_responder_cooldown}
  catch
    _kind, _reason -> {:error, :invalid_responder_cooldown}
  end

  def validate(_recorded, _configuration, _cooldowns, _settings),
    do: {:error, :invalid_responder_cooldown}

  defp resolve_persona(published, configuration) do
    persona = published.started.plan.publication.persona

    case Map.fetch(configuration.personas.personas, persona.id) do
      {:ok, %Persona{} = current} when current === persona ->
        if Validator.validate(current) == :ok,
          do: {:ok, current},
          else: {:error, :invalid_responder_cooldown}

      _failure ->
        {:error, :invalid_responder_cooldown}
    end
  end

  defp cooldown_facts(published, persona) do
    spoken_at = published.attempt.completed_at
    cooldown_ms = Map.get(persona.behavior, "cooldown_ms", 0)
    cooldown_until = DateTime.add(spoken_at, cooldown_ms * 1_000, :microsecond)
    {:ok, spoken_at, cooldown_until}
  rescue
    _error -> {:error, :invalid_responder_cooldown}
  catch
    _kind, _reason -> {:error, :invalid_responder_cooldown}
  end

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :record_spoken, 3),
      do: :ok,
      else: {:error, :storage_unavailable}
  end

  defp safe_record(store, persona_id, spoken_at, cooldown_until) do
    store.record_spoken(persona_id, spoken_at, cooldown_until)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp validate_result(cooldown, persona_id, spoken_at, cooldown_until) do
    if PersonaCooldownRecordValidator.validate(cooldown) == :ok and
         cooldown.persona_id === persona_id and same_datetime?(cooldown.last_spoken_at, spoken_at) and
         same_datetime?(cooldown.cooldown_until, cooldown_until),
       do: :ok,
       else: {:error, :invalid_persona_cooldown_record}
  end

  defp exact_recorded?(recorded) do
    map_size(recorded) == @recorded_key_count and
      Enum.all?(@recorded_keys, &Map.has_key?(recorded, &1))
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false
end

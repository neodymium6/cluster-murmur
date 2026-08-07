defmodule ClusterMurmur.Discord.StarterPublicationStarter do
  @moduledoc """
  Durably starts one planned starter-message publication attempt.

  The boundary revalidates the complete starter publication plan against current
  inputs, delegates durable intent recording to a narrow injected store, and
  returns only an exact correlated started attempt. It performs no external
  request.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Discord.{
    StarterPublicationPlanner,
    WebhookSettings
  }

  alias ClusterMurmur.Discord.StarterPublicationPlanner.Plan

  alias ClusterMurmur.Persistence.{
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator,
    PublicationAttemptStore
  }

  defmodule Started do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:plan, :attempt]
    defstruct [:plan, :attempt]

    @type t :: %__MODULE__{
            plan: ClusterMurmur.Discord.StarterPublicationPlanner.Plan.t(),
            attempt: ClusterMurmur.Persistence.PublicationAttemptRecord.t()
          }
  end

  @started_keys Started.__struct__() |> Map.keys()
  @started_key_count length(@started_keys)

  @type error ::
          :invalid_datetime
          | :invalid_message_record
          | :invalid_publication_attempt_record
          | :invalid_starter_publication
          | :publication_attempt_conflict
          | :publication_conflict
          | :storage_unavailable

  @doc "Records durable publication intent before any transport call."
  @spec start(term(), term(), term(), term(), term(), module()) ::
          {:ok, Started.t()} | {:error, error()}
  def start(
        plan,
        configuration,
        cooldowns,
        settings,
        started_at,
        store \\ PublicationAttemptStore
      )

  def start(
        %Plan{} = plan,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings,
        started_at,
        store
      )
      when is_atom(store) do
    with :ok <- StarterPublicationPlanner.validate(plan, configuration, cooldowns, settings),
         :ok <- validate_started_at(started_at, plan),
         :ok <- validate_store(store),
         {:ok, %PublicationAttemptRecord{} = attempt} <-
           persist(store, plan, settings, started_at),
         :ok <- validate_attempt_result(attempt, plan, started_at),
         started = %Started{plan: plan, attempt: attempt},
         :ok <- validate(started, configuration, cooldowns, settings) do
      {:ok, started}
    else
      {:error, reason}
      when reason in [
             :invalid_datetime,
             :invalid_message_record,
             :invalid_publication_attempt_record,
             :invalid_starter_publication,
             :publication_attempt_conflict,
             :publication_conflict,
             :storage_unavailable
           ] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  def start(_plan, _configuration, _cooldowns, _settings, _started_at, _store),
    do: {:error, :invalid_starter_publication}

  @doc "Revalidates one exact started attempt against current publication inputs."
  @spec validate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_starter_publication}
  def validate(
        %Started{} = started,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings
      ) do
    if exact_started?(started) and
         StarterPublicationPlanner.validate(started.plan, configuration, cooldowns, settings) ==
           :ok and
         correlated_attempt?(started.attempt, started.plan) do
      :ok
    else
      {:error, :invalid_starter_publication}
    end
  rescue
    _error -> {:error, :invalid_starter_publication}
  catch
    _kind, _reason -> {:error, :invalid_starter_publication}
  end

  def validate(_started, _configuration, _cooldowns, _settings),
    do: {:error, :invalid_starter_publication}

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :start, 5),
      do: :ok,
      else: {:error, :storage_unavailable}
  end

  defp validate_started_at(started_at, plan) do
    if DateTimeValidator.validate_storage_utc(started_at) == :ok and
         DateTime.compare(started_at, plan.persisted.message.inserted_at) in [:gt, :eq],
       do: :ok,
       else: {:error, :invalid_datetime}
  end

  defp persist(store, plan, settings, started_at) do
    publication = plan.publication

    store.start(
      publication,
      plan.persisted.message,
      publication.persona,
      settings,
      started_at
    )
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp correlated_attempt?(attempt, plan) do
    record = plan.persisted.message

    PublicationAttemptRecordValidator.validate(attempt) == :ok and attempt.status === :started and
      attempt.message_id === record.id and
      DateTime.compare(attempt.started_at, record.inserted_at) in [:gt, :eq] and
      is_nil(attempt.completed_at) and is_nil(attempt.error_class)
  end

  defp validate_attempt_result(attempt, plan, started_at) do
    if correlated_attempt?(attempt, plan) and same_datetime?(attempt.started_at, started_at),
      do: :ok,
      else: {:error, :invalid_publication_attempt_record}
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp exact_started?(started) do
    map_size(started) == @started_key_count and
      Enum.all?(@started_keys, &Map.has_key?(started, &1))
  end
end

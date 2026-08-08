defmodule ClusterMurmur.Discord.ResponderPublicationStarter do
  @moduledoc """
  Durably starts one planned responder-message publication attempt.

  The boundary revalidates the complete responder publication plan against
  current inputs, records durable intent through a narrow store, and returns an
  exact correlated started attempt. It performs no external request.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Discord.{ResponderPublicationPlanner, WebhookSettings}
  alias ClusterMurmur.Discord.ResponderPublicationPlanner.Plan

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
            plan: ClusterMurmur.Discord.ResponderPublicationPlanner.Plan.t(),
            attempt: ClusterMurmur.Persistence.PublicationAttemptRecord.t()
          }
  end

  @started_keys Started.__struct__() |> Map.keys()
  @started_key_count length(@started_keys)

  @type error ::
          :invalid_datetime
          | :invalid_message_record
          | :invalid_publication_attempt_record
          | :invalid_responder_publication
          | :publication_attempt_conflict
          | :publication_conflict
          | :storage_unavailable

  @doc "Records durable responder publication intent before transport I/O."
  @spec start(term(), term(), term(), term(), term(), module()) ::
          {:ok, Started.t()} | {:error, error()}
  def start(
        plan,
        configuration,
        current_cooldowns,
        settings,
        started_at,
        store \\ PublicationAttemptStore
      )

  def start(
        %Plan{} = plan,
        %Configuration{} = configuration,
        current_cooldowns,
        %WebhookSettings{} = settings,
        started_at,
        store
      )
      when is_atom(store) do
    with :ok <-
           ResponderPublicationPlanner.validate(
             plan,
             configuration,
             current_cooldowns,
             settings
           ),
         :ok <- validate_started_at(started_at, plan),
         :ok <- validate_store(store),
         {:ok, %PublicationAttemptRecord{} = attempt} <-
           persist(store, plan, settings, started_at),
         :ok <- validate_attempt_result(attempt, plan, started_at),
         started = %Started{plan: plan, attempt: attempt},
         :ok <- validate(started, configuration, current_cooldowns, settings) do
      {:ok, started}
    else
      {:error, reason}
      when reason in [
             :invalid_datetime,
             :invalid_message_record,
             :invalid_publication_attempt_record,
             :invalid_responder_publication,
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

  def start(_plan, _configuration, _current_cooldowns, _settings, _started_at, _store),
    do: {:error, :invalid_responder_publication}

  @doc "Revalidates one exact started responder publication capability."
  @spec validate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_responder_publication}
  def validate(
        %Started{} = started,
        %Configuration{} = configuration,
        current_cooldowns,
        %WebhookSettings{} = settings
      ) do
    if exact_started?(started) and
         ResponderPublicationPlanner.validate(
           started.plan,
           configuration,
           current_cooldowns,
           settings
         ) == :ok and correlated_attempt?(started.attempt, started.plan) do
      :ok
    else
      {:error, :invalid_responder_publication}
    end
  rescue
    _error -> {:error, :invalid_responder_publication}
  catch
    _kind, _reason -> {:error, :invalid_responder_publication}
  end

  def validate(_started, _configuration, _current_cooldowns, _settings),
    do: {:error, :invalid_responder_publication}

  defp validate_started_at(started_at, plan) do
    if DateTimeValidator.validate_storage_utc(started_at) == :ok and
         DateTime.compare(started_at, plan.delivery.message.inserted_at) in [:gt, :eq],
       do: :ok,
       else: {:error, :invalid_datetime}
  end

  defp validate_store(store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :start, 5),
      do: :ok,
      else: {:error, :storage_unavailable}
  end

  defp persist(store, plan, settings, started_at) do
    publication = plan.publication

    store.start(
      publication,
      plan.delivery.message,
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
    message = plan.delivery.message

    PublicationAttemptRecordValidator.validate(attempt) == :ok and attempt.status === :started and
      attempt.message_id === message.id and
      DateTime.compare(attempt.started_at, message.inserted_at) in [:gt, :eq] and
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

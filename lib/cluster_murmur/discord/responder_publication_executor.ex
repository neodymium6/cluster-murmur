defmodule ClusterMurmur.Discord.ResponderPublicationExecutor do
  @moduledoc """
  Executes and closes one exact started responder-message publication.

  The executor revalidates the redacted started capability and current inputs,
  delegates the one-use dispatch claim plus transport call to an injected
  publisher, and records exactly one classified terminal outcome through an
  injected narrow store. It never exposes transport values or retries an
  ambiguous external effect.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Discord.{
    ResponderPublicationStarter,
    WebhookPublisher,
    WebhookSettings
  }

  alias ClusterMurmur.Discord.ResponderPublicationStarter.Started

  alias ClusterMurmur.Persistence.{
    MessageRecord,
    MessageRecordValidator,
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator,
    PublicationAttemptStore
  }

  defmodule Outcome do
    @moduledoc false

    @derive {Inspect, only: [:status, :error_class]}
    @enforce_keys [:started, :attempt, :status, :error_class]
    defstruct [:started, :attempt, :message, :status, :error_class]

    @type t :: %__MODULE__{
            started: ClusterMurmur.Discord.ResponderPublicationStarter.Started.t(),
            attempt: ClusterMurmur.Persistence.PublicationAttemptRecord.t(),
            message: ClusterMurmur.Persistence.MessageRecord.t() | nil,
            status: :succeeded | :failed | :ambiguous,
            error_class: atom() | nil
          }
  end

  @outcome_keys Outcome.__struct__() |> Map.keys()
  @outcome_key_count length(@outcome_keys)
  @publisher_errors [
    :invalid_publication_attempt_record,
    :invalid_request,
    :publication_attempt_conflict,
    :storage_unavailable
  ]
  @store_errors [
    :invalid_datetime,
    :invalid_external_error,
    :invalid_message_id,
    :invalid_message_record,
    :invalid_publication_id,
    :invalid_publication_attempt_record,
    :invalid_publication_plan,
    :publication_attempt_conflict,
    :publication_conflict,
    :storage_unavailable
  ]
  @external_errors [
    :authentication_failed,
    :invalid_request,
    :invalid_response,
    :rate_limited,
    :timeout,
    :unavailable
  ]

  @type error ::
          :invalid_datetime
          | :invalid_external_error
          | :invalid_message_id
          | :invalid_message_record
          | :invalid_publication_id
          | :invalid_publication_attempt_record
          | :invalid_publication_outcome
          | :invalid_publication_plan
          | :invalid_responder_publication
          | :invalid_transport
          | :publication_attempt_conflict
          | :publication_conflict
          | :publisher_unavailable
          | :storage_unavailable

  @type result ::
          {:ok, Outcome.t()}
          | {:failed, atom(), Outcome.t()}
          | {:ambiguous, :interrupted, Outcome.t()}
          | {:error, error()}

  @doc "Executes one started publication and durably classifies its outcome."
  @spec execute(term(), term(), term(), term(), term(), term(), module(), module()) :: result()
  def execute(
        started,
        configuration,
        cooldowns,
        settings,
        completed_at,
        transport,
        publisher \\ WebhookPublisher,
        store \\ PublicationAttemptStore
      )

  def execute(
        %Started{} = started,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings,
        completed_at,
        transport,
        publisher,
        store
      )
      when is_atom(publisher) and is_atom(store) do
    with :ok <- ResponderPublicationStarter.validate(started, configuration, cooldowns, settings),
         {:ok, completed_at} <- validate_completed_at(completed_at, started),
         :ok <- validate_transport(transport),
         :ok <- validate_publisher(publisher),
         :ok <- validate_store(store) do
      publish(started, settings, completed_at, transport, publisher, store)
    end
  rescue
    _error -> {:error, :publisher_unavailable}
  catch
    _kind, _reason -> {:error, :publisher_unavailable}
  end

  def execute(
        _started,
        _configuration,
        _cooldowns,
        _settings,
        _completed_at,
        _transport,
        _publisher,
        _store
      ),
      do: {:error, :invalid_responder_publication}

  @doc "Revalidates one exact redacted terminal publication capability."
  @spec validate(term(), term(), term(), term()) ::
          :ok | {:error, :invalid_publication_outcome}
  def validate(
        %Outcome{} = outcome,
        %Configuration{} = configuration,
        cooldowns,
        %WebhookSettings{} = settings
      ) do
    if exact_outcome?(outcome) and
         ResponderPublicationStarter.validate(outcome.started, configuration, cooldowns, settings) ==
           :ok and correlated_terminal?(outcome) do
      :ok
    else
      {:error, :invalid_publication_outcome}
    end
  rescue
    _error -> {:error, :invalid_publication_outcome}
  catch
    _kind, _reason -> {:error, :invalid_publication_outcome}
  end

  def validate(_outcome, _configuration, _cooldowns, _settings),
    do: {:error, :invalid_publication_outcome}

  defp publish(started, settings, completed_at, transport, publisher, store) do
    plan = started.plan
    message = plan.delivery.message
    persona = plan.publication.persona

    result =
      safe_publish(
        publisher,
        started.attempt,
        plan.publication,
        message,
        persona,
        settings,
        transport
      )

    close(result, started, message, completed_at, store)
  end

  defp close({:ok, discord_message_id, dispatching}, started, message, completed_at, store) do
    with :ok <- validate_dispatching(dispatching, started),
         {:ok, {%PublicationAttemptRecord{} = attempt, %MessageRecord{} = published}} <-
           safe_store(store, :succeed, [dispatching, message, discord_message_id, completed_at]),
         :ok <-
           validate_success(
             attempt,
             published,
             dispatching,
             message,
             discord_message_id,
             completed_at
           ) do
      outcome = terminal_outcome(started, attempt, published)

      if validate_outcome_shape(outcome) == :ok,
        do: {:ok, outcome},
        else: {:error, :invalid_publication_outcome}
    else
      {:error, reason} -> store_or_outcome_error(reason)
      _failure -> {:error, :invalid_publication_outcome}
    end
  end

  defp close({:failed, error_class, dispatching}, started, _message, completed_at, store)
       when error_class in @external_errors do
    with :ok <- validate_dispatching(dispatching, started),
         {:ok, %PublicationAttemptRecord{} = attempt} <-
           safe_store(store, :fail, [dispatching, error_class, completed_at]),
         :ok <- validate_terminal(attempt, dispatching, :failed, error_class, completed_at) do
      outcome = terminal_outcome(started, attempt, nil)

      if validate_outcome_shape(outcome) == :ok,
        do: {:failed, error_class, outcome},
        else: {:error, :invalid_publication_outcome}
    else
      {:error, reason} -> store_or_outcome_error(reason)
      _failure -> {:error, :invalid_publication_outcome}
    end
  end

  defp close(
         {:ambiguous, :interrupted, dispatching},
         started,
         _message,
         completed_at,
         store
       ) do
    with :ok <- validate_dispatching(dispatching, started),
         {:ok, %PublicationAttemptRecord{} = attempt} <-
           safe_store(store, :mark_ambiguous, [dispatching, completed_at]),
         :ok <- validate_terminal(attempt, dispatching, :ambiguous, :interrupted, completed_at) do
      outcome = terminal_outcome(started, attempt, nil)

      if validate_outcome_shape(outcome) == :ok,
        do: {:ambiguous, :interrupted, outcome},
        else: {:error, :invalid_publication_outcome}
    else
      {:error, reason} -> store_or_outcome_error(reason)
      _failure -> {:error, :invalid_publication_outcome}
    end
  end

  defp close({:error, reason}, _started, _message, _completed_at, _store)
       when reason in @publisher_errors,
       do: {:error, reason}

  defp close({:error, :publisher_unavailable}, _started, _message, _completed_at, _store),
    do: {:error, :publisher_unavailable}

  defp close(_invalid, _started, _message, _completed_at, _store),
    do: {:error, :invalid_publication_outcome}

  defp validate_completed_at(completed_at, started) do
    if DateTimeValidator.validate_storage_utc(completed_at) == :ok and
         DateTime.compare(completed_at, started.attempt.started_at) in [:gt, :eq],
       do: {:ok, normalize_microsecond_precision(completed_at)},
       else: {:error, :invalid_datetime}
  end

  defp normalize_microsecond_precision(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  defp validate_transport(transport) when is_function(transport, 1), do: :ok
  defp validate_transport(_transport), do: {:error, :invalid_transport}

  defp validate_publisher(publisher) do
    if Code.ensure_loaded?(publisher) and function_exported?(publisher, :publish, 6),
      do: :ok,
      else: {:error, :publisher_unavailable}
  end

  defp validate_store(store) do
    required = [succeed: 4, fail: 3, mark_ambiguous: 2]

    if Code.ensure_loaded?(store) and
         Enum.all?(required, fn {function, arity} ->
           function_exported?(store, function, arity)
         end),
       do: :ok,
       else: {:error, :storage_unavailable}
  end

  defp safe_publish(publisher, attempt, plan, message, persona, settings, transport) do
    publisher.publish(attempt, plan, message, persona, settings, transport)
  rescue
    _error -> {:error, :publisher_unavailable}
  catch
    _kind, _reason -> {:error, :publisher_unavailable}
  end

  defp safe_store(store, function, arguments) do
    apply(store, function, arguments)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp validate_dispatching(%PublicationAttemptRecord{} = dispatching, started) do
    expected = %{started.attempt | status: :dispatching}

    if PublicationAttemptRecordValidator.validate(dispatching) == :ok and
         dispatching === expected,
       do: :ok,
       else: {:error, :invalid_publication_attempt_record}
  end

  defp validate_dispatching(_dispatching, _started),
    do: {:error, :invalid_publication_attempt_record}

  defp validate_success(
         attempt,
         published,
         dispatching,
         message,
         discord_message_id,
         completed_at
       ) do
    with :ok <- validate_terminal(attempt, dispatching, :succeeded, nil, completed_at),
         :ok <- MessageRecordValidator.validate(published),
         true <- is_binary(discord_message_id),
         true <- published.discord_message_id === discord_message_id,
         true <- same_message_except_publication?(published, message) do
      :ok
    else
      _failure -> {:error, :invalid_publication_outcome}
    end
  end

  defp validate_terminal(attempt, dispatching, status, error_class, completed_at) do
    expected = %{
      dispatching
      | status: status,
        completed_at: completed_at,
        error_class: error_class
    }

    if PublicationAttemptRecordValidator.validate(attempt) == :ok and attempt === expected,
      do: :ok,
      else: {:error, :invalid_publication_attempt_record}
  end

  defp same_message_except_publication?(published, message) do
    %{published | discord_message_id: nil} === message and is_binary(published.discord_message_id)
  end

  defp terminal_outcome(started, attempt, message) do
    %Outcome{
      started: started,
      attempt: attempt,
      message: message,
      status: attempt.status,
      error_class: attempt.error_class
    }
  end

  defp validate_outcome_shape(%Outcome{} = outcome) do
    if exact_outcome?(outcome) and correlated_terminal?(outcome),
      do: :ok,
      else: {:error, :invalid_publication_outcome}
  end

  defp correlated_terminal?(outcome) do
    started = outcome.started
    attempt = outcome.attempt

    PublicationAttemptRecordValidator.validate(attempt) == :ok and
      attempt.message_id === started.attempt.message_id and
      same_datetime?(attempt.started_at, started.attempt.started_at) and
      outcome.status === attempt.status and outcome.error_class === attempt.error_class and
      valid_terminal_message?(outcome)
  end

  defp valid_terminal_message?(%Outcome{
         status: :succeeded,
         error_class: nil,
         message: %MessageRecord{} = message,
         started: started
       }) do
    MessageRecordValidator.validate(message) == :ok and
      message.id === started.plan.delivery.message.id and
      same_message_except_publication?(message, started.plan.delivery.message)
  end

  defp valid_terminal_message?(%Outcome{
         status: :failed,
         error_class: error_class,
         message: nil
       })
       when error_class in @external_errors,
       do: true

  defp valid_terminal_message?(%Outcome{
         status: :ambiguous,
         error_class: :interrupted,
         message: nil
       }),
       do: true

  defp valid_terminal_message?(_outcome), do: false

  defp exact_outcome?(outcome) do
    map_size(outcome) == @outcome_key_count and
      Enum.all?(@outcome_keys, &Map.has_key?(outcome, &1))
  end

  defp store_or_outcome_error(reason) when reason in @store_errors, do: {:error, reason}
  defp store_or_outcome_error(_reason), do: {:error, :invalid_publication_outcome}

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false
end

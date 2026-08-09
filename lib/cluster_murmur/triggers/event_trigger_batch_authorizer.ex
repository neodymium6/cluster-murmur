defmodule ClusterMurmur.Triggers.EventTriggerBatchAuthorizer do
  @moduledoc """
  Selects and durably authorizes one bounded event-trigger batch.

  Matching remains application-owned and deterministic. Selected triggers are
  passed once, in stable ID order, to an injected one-trigger authorizer. The
  batch retains only validated redacted capabilities and stable skip or failure
  classes. It does not execute any authorized action.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Triggers.{EventSelector, EventTriggerAuthorizer}
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization

  defmodule Result do
    @moduledoc false

    @derive {
      Inspect,
      only: [:selected_count, :authorized_count, :skipped_count, :failure_count]
    }
    @enforce_keys [
      :event,
      :executed_at,
      :selected_count,
      :authorized_count,
      :skipped_count,
      :failure_count,
      :authorizations,
      :skips,
      :failures
    ]
    defstruct [
      :event,
      :executed_at,
      :selected_count,
      :authorized_count,
      :skipped_count,
      :failure_count,
      :authorizations,
      :skips,
      :failures
    ]

    @type skip_reason :: :already_terminal | :cooldown | :dedupe_window | :execution_in_progress
    @type failure_reason ::
            :authorization_failed
            | :event_conflict
            | :event_not_found
            | :invalid_execution
            | :storage_unavailable

    @type t :: %__MODULE__{
            event: ClusterMurmur.Events.Event.t(),
            executed_at: DateTime.t(),
            selected_count: non_neg_integer(),
            authorized_count: non_neg_integer(),
            skipped_count: non_neg_integer(),
            failure_count: non_neg_integer(),
            authorizations: [
              ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization.t()
            ],
            skips: [skip_reason()],
            failures: [failure_reason()]
          }
  end

  @max_triggers 256
  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)
  @skip_reasons [:already_terminal, :cooldown, :dedupe_window, :execution_in_progress]
  @failure_reasons [
    :authorization_failed,
    :event_conflict,
    :event_not_found,
    :invalid_execution,
    :storage_unavailable
  ]

  @type error ::
          EventSelector.error()
          | :invalid_batch_authorization
          | :invalid_datetime
          | :invalid_event

  @doc "Authorizes every matching trigger once in stable order without acting."
  @spec authorize_matching(term(), term(), term(), module()) ::
          {:ok, Result.t()} | {:error, error()}
  def authorize_matching(
        triggers,
        event,
        executed_at,
        authorizer \\ EventTriggerAuthorizer
      )

  def authorize_matching(triggers, %Event{} = event, executed_at, authorizer)
      when is_atom(authorizer) do
    with :ok <- validate_event(event),
         :ok <- validate_executed_at(executed_at),
         :ok <- validate_authorizer(authorizer),
         {:ok, selected} <- EventSelector.select(triggers, event),
         result <- authorize_selected(selected, event, executed_at, authorizer),
         :ok <- validate_result(result, triggers) do
      {:ok, result}
    else
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_batch_authorization}
    end
  rescue
    _error -> {:error, :invalid_batch_authorization}
  catch
    _kind, _reason -> {:error, :invalid_batch_authorization}
  end

  def authorize_matching(_triggers, %Event{}, _executed_at, _authorizer),
    do: {:error, :invalid_batch_authorization}

  def authorize_matching(_triggers, _event, _executed_at, _authorizer),
    do: {:error, :invalid_event}

  @doc "Revalidates one exact result against its bounded trigger catalog."
  @spec validate_result(term(), term()) :: :ok | {:error, :invalid_batch_authorization}
  def validate_result(%Result{} = result, triggers) do
    with true <- exact_result?(result),
         :ok <- validate_event(result.event),
         :ok <- validate_executed_at(result.executed_at),
         {:ok, selected} <- select_for_validation(triggers, result.event),
         true <- valid_count_values?(result),
         true <- result.selected_count == length(selected),
         {:ok, authorized_count} <-
           validate_authorizations(
             result.authorizations,
             result.event,
             result.executed_at,
             Map.new(selected, &{&1.id, &1}),
             nil,
             0
           ),
         {:ok, skipped_count} <- validate_classes(result.skips, @skip_reasons, 0),
         {:ok, failure_count} <- validate_classes(result.failures, @failure_reasons, 0),
         true <- valid_count_relations?(result, authorized_count, skipped_count, failure_count) do
      :ok
    else
      _failure -> {:error, :invalid_batch_authorization}
    end
  rescue
    _error -> {:error, :invalid_batch_authorization}
  catch
    _kind, _reason -> {:error, :invalid_batch_authorization}
  end

  def validate_result(_result, _triggers), do: {:error, :invalid_batch_authorization}

  defp select_for_validation(triggers, event) do
    case EventSelector.select(triggers, event) do
      {:ok, selected} -> {:ok, selected}
      {:error, _reason} -> {:error, :invalid_batch_authorization}
    end
  end

  defp validate_event(event) do
    case Validator.validate(event) do
      :ok -> :ok
      {:error, :invalid_event} -> {:error, :invalid_event}
    end
  end

  defp validate_executed_at(executed_at) do
    case DateTimeValidator.validate_storage_utc(executed_at) do
      :ok -> :ok
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
    end
  end

  defp validate_authorizer(authorizer) do
    if Code.ensure_loaded?(authorizer) and function_exported?(authorizer, :authorize, 3),
      do: :ok,
      else: {:error, :invalid_batch_authorization}
  end

  defp authorize_selected(selected, event, executed_at, authorizer) do
    {authorizations, skips, failures} =
      Enum.reduce(selected, {[], [], []}, fn trigger, {authorized, skipped, failed} ->
        case authorize_one(authorizer, trigger, event, executed_at) do
          {:ok, authorization} -> {[authorization | authorized], skipped, failed}
          {:skip, reason} -> {authorized, [reason | skipped], failed}
          {:error, reason} -> {authorized, skipped, [reason | failed]}
        end
      end)

    authorizations = Enum.reverse(authorizations)
    skips = Enum.reverse(skips)
    failures = Enum.reverse(failures)

    %Result{
      event: event,
      executed_at: executed_at,
      selected_count: length(selected),
      authorized_count: length(authorizations),
      skipped_count: length(skips),
      failure_count: length(failures),
      authorizations: authorizations,
      skips: skips,
      failures: failures
    }
  end

  defp authorize_one(authorizer, trigger, event, executed_at) do
    case authorizer.authorize(trigger, event, executed_at) do
      {:ok, %Authorization{} = authorization} ->
        if valid_authorization?(authorization, trigger, event, executed_at),
          do: {:ok, authorization},
          else: {:error, :authorization_failed}

      {:skip, reason} when reason in @skip_reasons ->
        {:skip, reason}

      {:error, reason} when reason in @failure_reasons ->
        {:error, reason}

      _failure ->
        {:error, :authorization_failed}
    end
  rescue
    _error -> {:error, :authorization_failed}
  catch
    _kind, _reason -> {:error, :authorization_failed}
  end

  defp valid_authorization?(authorization, trigger, event, executed_at) do
    EventTriggerAuthorizer.validate(authorization) == :ok and
      authorization.plan.trigger === trigger and authorization.plan.event === event and
      same_datetime?(authorization.plan.executed_at, executed_at)
  end

  defp validate_authorizations(
         [],
         _event,
         _executed_at,
         _selected_by_id,
         _previous_id,
         count
       ),
       do: {:ok, count}

  defp validate_authorizations(
         [%Authorization{} = authorization | authorizations],
         event,
         executed_at,
         selected_by_id,
         previous_id,
         count
       )
       when count < @max_triggers do
    trigger_id = authorization.plan.trigger.id

    case Map.fetch(selected_by_id, trigger_id) do
      {:ok, selected_trigger} ->
        if EventTriggerAuthorizer.validate(authorization) == :ok and
             authorization.plan.trigger === selected_trigger and
             authorization.plan.event === event and
             same_datetime?(authorization.plan.executed_at, executed_at) and
             ascending_id?(previous_id, trigger_id) do
          validate_authorizations(
            authorizations,
            event,
            executed_at,
            selected_by_id,
            trigger_id,
            count + 1
          )
        else
          {:error, :invalid_batch_authorization}
        end

      :error ->
        {:error, :invalid_batch_authorization}
    end
  end

  defp validate_authorizations(
         _authorizations,
         _event,
         _executed_at,
         _selected_by_id,
         _previous_id,
         _count
       ),
       do: {:error, :invalid_batch_authorization}

  defp validate_classes([], _allowed, count), do: {:ok, count}

  defp validate_classes([reason | reasons], allowed, count) when count < @max_triggers do
    if reason in allowed,
      do: validate_classes(reasons, allowed, count + 1),
      else: {:error, :invalid_batch_authorization}
  end

  defp validate_classes(_reasons, _allowed, _count),
    do: {:error, :invalid_batch_authorization}

  defp ascending_id?(nil, trigger_id), do: is_binary(trigger_id)
  defp ascending_id?(previous_id, trigger_id), do: previous_id < trigger_id

  defp valid_count_values?(result) do
    counts = [
      result.selected_count,
      result.authorized_count,
      result.skipped_count,
      result.failure_count
    ]

    Enum.all?(counts, &(is_integer(&1) and &1 in 0..@max_triggers))
  end

  defp valid_count_relations?(result, authorized_count, skipped_count, failure_count) do
    result.authorized_count == authorized_count and result.skipped_count == skipped_count and
      result.failure_count == failure_count and
      result.selected_count == authorized_count + skipped_count + failure_count
  end

  defp exact_result?(result) do
    map_size(result) == @result_key_count and Enum.all?(@result_keys, &Map.has_key?(result, &1))
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false
end

defmodule ClusterMurmur.Triggers.PollEventTriggerDispatcher do
  @moduledoc """
  Authorizes and synchronously dispatches one bounded poll trigger plan.

  Every planned event-trigger match is authorized once in deterministic order.
  A successful authorization crosses directly into one fixed starter consumer
  before later matches are attempted. The returned value is only a redacted
  report and contains no reusable authorization capability.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult

  alias ClusterMurmur.Triggers.{
    EventTriggerAuthorizer,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization
  alias ClusterMurmur.Triggers.PollEventTriggerPlanner.{Entry, Plan}

  defmodule Outcome do
    @moduledoc false

    @derive {Inspect, only: [:status, :reason]}
    @enforce_keys [:status, :reason]
    defstruct [:status, :reason]

    @type reason ::
            :already_terminal
            | :authorization_failed
            | :cooldown
            | :dedupe_window
            | :dispatch_failed
            | :event_conflict
            | :event_not_found
            | :execution_in_progress
            | :invalid_execution
            | :storage_unavailable
            | nil

    @type t :: %__MODULE__{
            status: :dispatched | :skipped | :failed,
            reason: reason()
          }
  end

  defmodule Result do
    @moduledoc false

    @derive {
      Inspect,
      only: [:match_count, :dispatched_count, :skipped_count, :failure_count]
    }
    @enforce_keys [
      :match_count,
      :dispatched_count,
      :skipped_count,
      :failure_count,
      :outcomes
    ]
    defstruct [
      :match_count,
      :dispatched_count,
      :skipped_count,
      :failure_count,
      :outcomes
    ]

    @type t :: %__MODULE__{
            match_count: non_neg_integer(),
            dispatched_count: non_neg_integer(),
            skipped_count: non_neg_integer(),
            failure_count: non_neg_integer(),
            outcomes: [ClusterMurmur.Triggers.PollEventTriggerDispatcher.Outcome.t()]
          }
  end

  @skip_reasons [:already_terminal, :cooldown, :dedupe_window, :execution_in_progress]
  @failure_reasons [
    :authorization_failed,
    :event_conflict,
    :event_not_found,
    :invalid_execution,
    :storage_unavailable
  ]

  @type error :: :invalid_poll_event_dispatch

  @doc "Authorizes and dispatches every planned match once, returning only a report."
  @spec dispatch(term(), term(), term(), module(), term(), module()) ::
          {:ok, Result.t()} | {:error, error()}
  def dispatch(
        plan,
        poll_result,
        configuration,
        consumer,
        consumer_context,
        authorizer \\ EventTriggerAuthorizer
      )

  def dispatch(
        %Plan{} = plan,
        %PollResult{} = poll_result,
        %Configuration{} = configuration,
        consumer,
        consumer_context,
        authorizer
      )
      when is_atom(consumer) and is_atom(authorizer) do
    with :ok <- PollEventTriggerPlanner.validate(plan, poll_result, configuration),
         :ok <- validate_authorizer(authorizer),
         :ok <- validate_consumer(consumer),
         :ok <- preflight_consumer(consumer, plan, poll_result, configuration, consumer_context) do
      {:ok,
       dispatch_matches(
         plan,
         configuration.event_policy,
         authorizer,
         consumer,
         consumer_context
       )}
    else
      _failure -> {:error, :invalid_poll_event_dispatch}
    end
  rescue
    _error -> {:error, :invalid_poll_event_dispatch}
  catch
    _kind, _reason -> {:error, :invalid_poll_event_dispatch}
  end

  def dispatch(
        _plan,
        _poll_result,
        _configuration,
        _consumer,
        _consumer_context,
        _authorizer
      ),
      do: {:error, :invalid_poll_event_dispatch}

  defp validate_authorizer(authorizer) do
    if Code.ensure_loaded?(authorizer) and function_exported?(authorizer, :authorize, 4),
      do: :ok,
      else: {:error, :invalid_poll_event_dispatch}
  end

  defp validate_consumer(consumer) do
    if Code.ensure_loaded?(consumer) and function_exported?(consumer, :preflight, 4) and
         function_exported?(consumer, :consume, 3),
       do: :ok,
       else: {:error, :invalid_poll_event_dispatch}
  end

  defp preflight_consumer(consumer, plan, poll_result, configuration, consumer_context) do
    case consumer.preflight(plan, poll_result, configuration, consumer_context) do
      :ok -> :ok
      _failure -> {:error, :invalid_poll_event_dispatch}
    end
  rescue
    _error -> {:error, :invalid_poll_event_dispatch}
  catch
    _kind, _reason -> {:error, :invalid_poll_event_dispatch}
  end

  defp dispatch_matches(plan, event_policy, authorizer, consumer, consumer_context) do
    outcomes =
      plan.entries
      |> expected_matches()
      |> Enum.with_index()
      |> Enum.map(fn {{event, trigger}, index} ->
        authorize_and_consume(
          authorizer,
          consumer,
          consumer_context,
          event,
          trigger,
          plan.executed_at,
          event_policy,
          index
        )
      end)

    {dispatched_count, skipped_count, failure_count} = count_outcomes(outcomes, 0, 0, 0)

    %Result{
      match_count: plan.match_count,
      dispatched_count: dispatched_count,
      skipped_count: skipped_count,
      failure_count: failure_count,
      outcomes: outcomes
    }
  end

  defp authorize_and_consume(
         authorizer,
         consumer,
         consumer_context,
         event,
         trigger,
         executed_at,
         event_policy,
         index
       ) do
    case authorize_one(authorizer, event, trigger, executed_at, event_policy) do
      {:ok, authorization} -> consume_one(consumer, authorization, index, consumer_context)
      {:skip, reason} -> %Outcome{status: :skipped, reason: reason}
      {:error, reason} -> %Outcome{status: :failed, reason: reason}
    end
  end

  defp authorize_one(authorizer, event, trigger, executed_at, event_policy) do
    case authorizer.authorize(trigger, event, executed_at, event_policy) do
      {:ok, %Authorization{} = authorization} ->
        if valid_authorization?(authorization, event, trigger, event_policy, executed_at),
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

  defp consume_one(consumer, authorization, index, consumer_context) do
    case consumer.consume(authorization, index, consumer_context) do
      :ok -> %Outcome{status: :dispatched, reason: nil}
      _failure -> %Outcome{status: :failed, reason: :dispatch_failed}
    end
  rescue
    _error -> %Outcome{status: :failed, reason: :dispatch_failed}
  catch
    _kind, _reason -> %Outcome{status: :failed, reason: :dispatch_failed}
  end

  defp valid_authorization?(authorization, event, trigger, event_policy, executed_at) do
    EventTriggerAuthorizer.validate(authorization) == :ok and
      authorization.plan.event === event and authorization.plan.trigger === trigger and
      authorization.plan.event_policy === event_policy and
      same_datetime?(authorization.plan.executed_at, executed_at)
  end

  defp expected_matches(entries) do
    Enum.flat_map(entries, fn %Entry{} = entry ->
      Enum.map(entry.triggers, &{entry.event, &1})
    end)
  end

  defp count_outcomes([], dispatched, skipped, failed),
    do: {dispatched, skipped, failed}

  defp count_outcomes([%Outcome{status: :dispatched} | outcomes], dispatched, skipped, failed),
    do: count_outcomes(outcomes, dispatched + 1, skipped, failed)

  defp count_outcomes([%Outcome{status: :skipped} | outcomes], dispatched, skipped, failed),
    do: count_outcomes(outcomes, dispatched, skipped + 1, failed)

  defp count_outcomes([%Outcome{status: :failed} | outcomes], dispatched, skipped, failed),
    do: count_outcomes(outcomes, dispatched, skipped, failed + 1)

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false
end

defmodule ClusterMurmur.Runtime.EventDispatchExecutor do
  @moduledoc false

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.{EventDispatch, EventDispatchClaim}
  alias ClusterMurmur.Runtime.EventDispatchCycle.Result
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer
  alias ClusterMurmur.Triggers.EventDispatchPlanner.Plan
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization

  @claim_lease_seconds 60
  @claim_token_bytes 32
  @terminal_skip_reasons [:already_terminal, :cooldown, :dedupe_window]
  @nonterminal_skip_reasons [:execution_in_progress]
  @failure_reasons [
    :authorization_failed,
    :event_conflict,
    :event_not_found,
    :invalid_execution,
    :storage_unavailable
  ]
  @claim_keys EventDispatchClaim.__struct__() |> Map.keys()
  @claim_key_count length(@claim_keys)
  @dispatch_keys EventDispatch.__struct__() |> Map.keys()
  @dispatch_key_count length(@dispatch_keys)

  @spec execute(Plan.t(), EventPolicy.t(), DateTime.t(), module(), struct(), module(), module()) ::
          Result.t() | {:error, :invalid_event_dispatch_cycle}
  def execute(
        %Plan{} = plan,
        %EventPolicy{} = event_policy,
        %DateTime{} = now,
        consumer,
        consumer_context,
        dispatches,
        authorizer
      )
      when is_atom(consumer) and is_struct(consumer_context) and is_atom(dispatches) and
             is_atom(authorizer) do
    initial = %Result{
      candidate_count: plan.candidate_count,
      claimed_count: 0,
      completed_count: 0,
      candidate_failure_count: 0,
      planned_match_count: plan.match_count,
      attempted_match_count: 0,
      dispatched_count: 0,
      skipped_count: 0,
      dispatch_failure_count: 0,
      dedupe_suppressed_count: 0
    }

    {result, _next_index} =
      Enum.reduce(plan.entries, {initial, 0}, fn entry, {result, match_index} ->
        execute_entry(
          entry,
          match_index,
          result,
          event_policy,
          now,
          consumer,
          consumer_context,
          dispatches,
          authorizer
        )
      end)

    result
  end

  def execute(
        _plan,
        _event_policy,
        _now,
        _consumer,
        _consumer_context,
        _dispatches,
        _authorizer
      ),
      do: {:error, :invalid_event_dispatch_cycle}

  defp execute_entry(
         entry,
         match_index,
         result,
         event_policy,
         now,
         consumer,
         consumer_context,
         dispatches,
         authorizer
       ) do
    next_index = match_index + length(entry.triggers)

    case claim(dispatches, entry.candidate, now) do
      {:ok, claim} ->
        {result, terminal?} =
          dispatch_matches(
            entry,
            match_index,
            %{result | claimed_count: result.claimed_count + 1},
            event_policy,
            now,
            consumer,
            consumer_context,
            authorizer
          )

        result =
          if terminal? and complete(dispatches, claim, now) == :ok do
            %{result | completed_count: result.completed_count + 1}
          else
            %{result | candidate_failure_count: result.candidate_failure_count + 1}
          end

        {result, next_index}

      :error ->
        {%{result | candidate_failure_count: result.candidate_failure_count + 1}, next_index}
    end
  end

  defp dispatch_matches(
         entry,
         match_index,
         result,
         event_policy,
         now,
         consumer,
         context,
         authorizer
       ) do
    entry.triggers
    |> Enum.with_index(match_index)
    |> Enum.reduce({result, true}, fn {trigger, index}, {result, terminal?} ->
      case authorize_and_consume(
             authorizer,
             consumer,
             context,
             entry.event,
             trigger,
             event_policy,
             now,
             index
           ) do
        :dispatched ->
          {%{
             result
             | attempted_match_count: result.attempted_match_count + 1,
               dispatched_count: result.dispatched_count + 1
           }, terminal?}

        {:skipped, reason} ->
          {%{
             result
             | attempted_match_count: result.attempted_match_count + 1,
               skipped_count: result.skipped_count + 1,
               dedupe_suppressed_count:
                 result.dedupe_suppressed_count + if(reason == :dedupe_window, do: 1, else: 0)
           }, terminal?}

        :failed ->
          {%{
             result
             | attempted_match_count: result.attempted_match_count + 1,
               dispatch_failure_count: result.dispatch_failure_count + 1
           }, false}
      end
    end)
  end

  defp authorize_and_consume(
         authorizer,
         consumer,
         context,
         event,
         trigger,
         event_policy,
         now,
         index
       ) do
    case authorizer.authorize(trigger, event, now, event_policy) do
      {:ok, %Authorization{} = authorization} ->
        if valid_authorization?(authorization, event, trigger, event_policy, now),
          do: consume(consumer, authorization, index, context),
          else: :failed

      {:skip, reason} when reason in @terminal_skip_reasons ->
        {:skipped, reason}

      {:skip, reason} when reason in @nonterminal_skip_reasons ->
        :failed

      {:error, reason} when reason in @failure_reasons ->
        :failed

      _failure ->
        :failed
    end
  rescue
    _error -> :failed
  catch
    _kind, _reason -> :failed
  end

  defp consume(consumer, authorization, index, context) do
    case consumer.consume(authorization, index, context) do
      :ok -> :dispatched
      _failure -> :failed
    end
  rescue
    _error -> :failed
  catch
    _kind, _reason -> :failed
  end

  defp valid_authorization?(authorization, event, trigger, event_policy, now) do
    EventTriggerAuthorizer.validate(authorization) == :ok and
      authorization.plan.event === event and authorization.plan.trigger === trigger and
      authorization.plan.event_policy === event_policy and
      authorization.plan.executed_at === now
  end

  defp claim(dispatches, candidate, now) do
    case dispatches.claim(candidate, now) do
      {:ok, %EventDispatchClaim{} = claim} ->
        if valid_claim?(claim, candidate, now), do: {:ok, claim}, else: :error

      _failure ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp valid_claim?(claim, candidate, now) do
    map_size(claim) == @claim_key_count and Enum.all?(@claim_keys, &Map.has_key?(claim, &1)) and
      claim.event_id == candidate.event_id and
      same_datetime?(claim.enqueued_at, candidate.enqueued_at) and valid_token?(claim.token) and
      same_datetime?(claim.started_at, now) and
      DateTimeValidator.validate_storage_utc(claim.expires_at) == :ok and
      same_datetime?(claim.expires_at, DateTime.add(now, @claim_lease_seconds, :second))
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_token?(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == @claim_token_bytes
      :error -> false
    end
  end

  defp valid_token?(_token), do: false

  defp complete(dispatches, claim, now) do
    case dispatches.complete(claim, now) do
      {:ok, %EventDispatch{} = dispatch} ->
        if completed_dispatch?(dispatch, claim, now), do: :ok, else: :error

      _failure ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp completed_dispatch?(dispatch, claim, now) do
    map_size(dispatch) == @dispatch_key_count and
      Enum.all?(@dispatch_keys, &Map.has_key?(dispatch, &1)) and
      dispatch.event_id == claim.event_id and
      same_datetime?(dispatch.enqueued_at, claim.enqueued_at) and
      dispatch.status == :completed and dispatch.claim_token == nil and
      dispatch.claim_started_at == nil and dispatch.claim_expires_at == nil and
      same_datetime?(dispatch.completed_at, now)
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false
end

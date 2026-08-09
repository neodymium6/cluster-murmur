defmodule ClusterMurmur.Persistence.EventRecordRetentionStore do
  @moduledoc """
  Advances one bounded event-retention sweep and prunes safe event records.

  Each transaction scans at most 100 expired events in deterministic index
  order. Events referenced by any trigger execution, conversation, dispatch,
  or dedupe marker remain unchanged, while the durable cursor advances past
  the complete scanned page. Only redacted aggregate counts leave the store.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{RetentionPlanner, Validator}
  alias ClusterMurmur.Events.RetentionPlanner.Plan

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    EventDedupeMarker,
    EventDispatch,
    EventRecord,
    EventRetentionSweep,
    TriggerExecution
  }

  alias ClusterMurmur.Repo

  @scope "events"
  @max_scanned 100
  @sweep_keys EventRetentionSweep.__struct__() |> Map.keys()
  @sweep_key_count length(@sweep_keys)

  defmodule Result do
    @moduledoc false

    @derive {Inspect, only: [:scanned_count, :pruned_event_count, :completed_pass?]}
    @enforce_keys [:scanned_count, :pruned_event_count, :completed_pass?]
    defstruct [:scanned_count, :pruned_event_count, :completed_pass?]

    @type t :: %__MODULE__{
            scanned_count: 0..100,
            pruned_event_count: 0..100,
            completed_pass?: boolean()
          }
  end

  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)

  @type error :: :invalid_retention_plan | :invalid_retention_sweep | :storage_unavailable

  @doc "Scans at most 100 expired events and deletes only unreferenced records."
  @spec prune(term()) :: {:ok, Result.t()} | {:error, error()}
  def prune(%Plan{} = plan) do
    case RetentionPlanner.validate(plan) do
      :ok -> transact(plan)
      {:error, :invalid_retention_plan} -> {:error, :invalid_retention_plan}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def prune(_plan), do: {:error, :invalid_retention_plan}

  @doc "Validates one exact bounded aggregate sweep result."
  @spec validate_result(term()) :: :ok | {:error, :invalid_event_retention_result}
  def validate_result(%Result{} = result) do
    if exact_result?(result) and valid_count?(result.scanned_count) and
         valid_count?(result.pruned_event_count) and
         result.pruned_event_count <= result.scanned_count and
         is_boolean(result.completed_pass?) and
         result.completed_pass? == result.scanned_count < @max_scanned,
       do: :ok,
       else: {:error, :invalid_event_retention_result}
  rescue
    _error -> {:error, :invalid_event_retention_result}
  catch
    _kind, _reason -> {:error, :invalid_event_retention_result}
  end

  def validate_result(_result), do: {:error, :invalid_event_retention_result}

  defp transact(plan) do
    case Repo.transaction(fn -> sweep_step(plan) end) do
      {:ok, %Result{} = result} ->
        case validate_result(result) do
          :ok -> {:ok, result}
          {:error, :invalid_event_retention_result} -> {:error, :storage_unavailable}
        end

      {:error, :invalid_retention_sweep} ->
        {:error, :invalid_retention_sweep}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp sweep_step(plan) do
    with {:ok, sweep} <- load_sweep(plan),
         {:ok, candidates} <- load_candidates(plan, sweep),
         {:ok, pruned_count} <- delete_unreferenced(candidates),
         :ok <- advance_sweep(sweep, candidates, plan.planned_at) do
      %Result{
        scanned_count: length(candidates),
        pruned_event_count: pruned_count,
        completed_pass?: length(candidates) < @max_scanned
      }
    else
      _failure -> Repo.rollback(:invalid_retention_sweep)
    end
  end

  defp load_sweep(plan) do
    case Repo.insert_all(
           EventRetentionSweep,
           [
             %{
               scope: @scope,
               cursor_occurred_at: nil,
               cursor_event_id: nil,
               swept_at: plan.planned_at
             }
           ],
           on_conflict: :nothing,
           conflict_target: [:scope]
         ) do
      {count, nil} when count in 0..1 -> restore_sweep()
      _failure -> {:error, :invalid_retention_sweep}
    end
  end

  defp restore_sweep do
    case Repo.get(EventRetentionSweep, @scope) do
      %EventRetentionSweep{} = sweep ->
        if valid_sweep?(sweep), do: {:ok, sweep}, else: {:error, :invalid_retention_sweep}

      _missing ->
        {:error, :invalid_retention_sweep}
    end
  end

  defp load_candidates(plan, sweep) do
    query =
      from event in EventRecord,
        where: event.occurred_at <= ^plan.cutoff,
        order_by: [asc: event.occurred_at, asc: event.id],
        limit: @max_scanned,
        select: %{id: event.id, occurred_at: event.occurred_at}

    query = after_cursor(query, sweep)

    case Repo.all(query) do
      candidates when is_list(candidates) -> validate_candidates(candidates, plan, sweep)
      _failure -> {:error, :invalid_retention_sweep}
    end
  end

  defp after_cursor(query, %EventRetentionSweep{
         cursor_occurred_at: nil,
         cursor_event_id: nil
       }),
       do: query

  defp after_cursor(query, sweep) do
    from event in query,
      where:
        event.occurred_at > ^sweep.cursor_occurred_at or
          (event.occurred_at == ^sweep.cursor_occurred_at and event.id > ^sweep.cursor_event_id)
  end

  defp validate_candidates(candidates, plan, sweep) do
    candidates
    |> Enum.reduce_while({:ok, nil, 0}, fn candidate, {:ok, previous, count} ->
      if count < @max_scanned and valid_candidate?(candidate, plan, sweep, previous) do
        {:cont, {:ok, candidate, count + 1}}
      else
        {:halt, {:error, :invalid_retention_sweep}}
      end
    end)
    |> case do
      {:ok, _previous, _count} -> {:ok, candidates}
      {:error, :invalid_retention_sweep} = error -> error
    end
  end

  defp valid_candidate?(%{id: id, occurred_at: occurred_at} = candidate, plan, sweep, previous) do
    map_size(candidate) == 2 and Validator.validate_id(id) == :ok and
      DateTimeValidator.validate_storage_utc(occurred_at) == :ok and
      DateTime.compare(occurred_at, plan.cutoff) in [:lt, :eq] and
      after_sweep_cursor?({occurred_at, id}, sweep) and
      after_previous?({occurred_at, id}, previous)
  end

  defp valid_candidate?(_candidate, _plan, _sweep, _previous), do: false

  defp after_sweep_cursor?(_candidate, %EventRetentionSweep{
         cursor_occurred_at: nil,
         cursor_event_id: nil
       }),
       do: true

  defp after_sweep_cursor?(candidate, sweep),
    do: cursor_after?(candidate, {sweep.cursor_occurred_at, sweep.cursor_event_id})

  defp after_previous?(_candidate, nil), do: true
  defp after_previous?(candidate, previous), do: cursor_after?(candidate, cursor(previous))

  defp cursor_after?({occurred_at, id}, {previous_at, previous_id}) do
    case DateTime.compare(occurred_at, previous_at) do
      :gt -> true
      :eq -> id > previous_id
      :lt -> false
    end
  end

  defp cursor(%{id: id, occurred_at: occurred_at}), do: {occurred_at, id}

  defp delete_unreferenced([]), do: {:ok, 0}

  defp delete_unreferenced(candidates) do
    candidate_ids = Enum.map(candidates, & &1.id)

    deletable_ids =
      from event in EventRecord,
        left_join: execution in TriggerExecution,
        on: execution.event_id == event.id,
        left_join: conversation in ConversationRecord,
        on: conversation.root_event_id == event.id,
        left_join: dispatch in EventDispatch,
        on: dispatch.event_id == event.id,
        left_join: marker in EventDedupeMarker,
        on: marker.event_id == event.id,
        where: event.id in ^candidate_ids,
        where: is_nil(execution.event_id),
        where: is_nil(conversation.root_event_id),
        where: is_nil(dispatch.event_id),
        where: is_nil(marker.event_id),
        select: event.id

    query =
      from event in EventRecord,
        where: event.id in subquery(deletable_ids)

    case Repo.delete_all(query) do
      {count, nil} when is_integer(count) and count >= 0 and count <= length(candidates) ->
        {:ok, count}

      _failure ->
        {:error, :invalid_retention_sweep}
    end
  end

  defp advance_sweep(sweep, candidates, swept_at) do
    {cursor_occurred_at, cursor_event_id} = next_cursor(candidates)

    base_query =
      from persisted in EventRetentionSweep,
        where: persisted.scope == ^@scope,
        where: persisted.swept_at == ^sweep.swept_at

    query = correlate_cursor(base_query, sweep)

    case Repo.update_all(query,
           set: [
             cursor_occurred_at: cursor_occurred_at,
             cursor_event_id: cursor_event_id,
             swept_at: swept_at
           ]
         ) do
      {1, nil} -> :ok
      _failure -> {:error, :invalid_retention_sweep}
    end
  end

  defp next_cursor(candidates) when length(candidates) < @max_scanned, do: {nil, nil}

  defp next_cursor(candidates) do
    %{id: id, occurred_at: occurred_at} = List.last(candidates)
    {occurred_at, id}
  end

  defp correlate_cursor(query, %EventRetentionSweep{
         cursor_occurred_at: nil,
         cursor_event_id: nil
       }) do
    from persisted in query,
      where: is_nil(persisted.cursor_occurred_at) and is_nil(persisted.cursor_event_id)
  end

  defp correlate_cursor(query, sweep) do
    from persisted in query,
      where:
        persisted.cursor_occurred_at == ^sweep.cursor_occurred_at and
          persisted.cursor_event_id == ^sweep.cursor_event_id
  end

  defp valid_sweep?(sweep) do
    exact_sweep?(sweep) and sweep.__meta__.state == :loaded and sweep.scope === @scope and
      DateTimeValidator.validate_storage_utc(sweep.swept_at) == :ok and valid_cursor?(sweep)
  end

  defp valid_cursor?(%EventRetentionSweep{
         cursor_occurred_at: nil,
         cursor_event_id: nil
       }),
       do: true

  defp valid_cursor?(sweep) do
    DateTimeValidator.validate_storage_utc(sweep.cursor_occurred_at) == :ok and
      Validator.validate_id(sweep.cursor_event_id) == :ok
  end

  defp exact_sweep?(sweep) do
    map_size(sweep) == @sweep_key_count and Enum.all?(@sweep_keys, &Map.has_key?(sweep, &1))
  end

  defp valid_count?(count), do: is_integer(count) and count in 0..@max_scanned

  defp exact_result?(result) do
    map_size(result) == @result_key_count and Enum.all?(@result_keys, &Map.has_key?(result, &1))
  end
end

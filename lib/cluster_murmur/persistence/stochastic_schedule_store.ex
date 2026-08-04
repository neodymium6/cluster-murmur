defmodule ClusterMurmur.Persistence.StochasticScheduleStore do
  @moduledoc """
  Restores or initializes stochastic schedule state through one bounded store API.

  Existing durable state always wins over a newly calculated initial run.
  Completed executions can advance state optimistically, while due claiming,
  action execution, and resampling remain outside this store.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.StochasticSchedule
  alias ClusterMurmur.Repo

  @max_due_schedules 100
  @max_daily_count 10_000

  @type error ::
          :daily_limit_reached
          | :invalid_datetime
          | :invalid_schedule
          | :schedule_conflict
          | :storage_unavailable

  @doc "Restores an existing schedule or atomically inserts its initial next run."
  @spec restore_or_initialize(term(), term()) ::
          {:ok, StochasticSchedule.t()} | {:error, error()}
  def restore_or_initialize(trigger_id, next_run_at) do
    changeset =
      StochasticSchedule.changeset(%StochasticSchedule{}, %{
        trigger_id: trigger_id,
        next_run_at: next_run_at
      })

    if changeset.valid? do
      persist(changeset, trigger_id)
    else
      {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Records a completed due execution and its next run in one transaction."
  @spec record_execution(term(), term(), term(), term(), term()) ::
          {:ok, StochasticSchedule.t()} | {:error, error()}
  def record_execution(trigger_id, expected_next_run_at, executed_at, next_run_at, local_date) do
    if valid_execution_input?(
         trigger_id,
         expected_next_run_at,
         executed_at,
         next_run_at,
         local_date
       ) do
      record_execution_transaction(
        trigger_id,
        expected_next_run_at,
        executed_at,
        next_run_at,
        local_date
      )
    else
      {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Returns at most 100 schedules due at or before one supplied UTC instant."
  @spec list_due(term()) :: {:ok, [StochasticSchedule.t()]} | {:error, error()}
  def list_due(now) do
    if valid_storage_datetime?(now) do
      query =
        from schedule in StochasticSchedule,
          where: schedule.next_run_at <= ^now,
          order_by: [asc: schedule.next_run_at, asc: schedule.trigger_id],
          limit: @max_due_schedules

      {:ok, Repo.all(query)}
    else
      {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp persist(changeset, trigger_id) do
    case Repo.transaction(fn -> insert_then_restore(changeset, trigger_id) end) do
      {:ok, %StochasticSchedule{} = schedule} -> {:ok, schedule}
      {:error, :invalid_schedule} -> {:error, :invalid_schedule}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp insert_then_restore(changeset, trigger_id) do
    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:trigger_id]
         ) do
      {:ok, _inserted_or_conflicted} ->
        case Repo.get(StochasticSchedule, trigger_id) do
          %StochasticSchedule{} = schedule -> schedule
          nil -> Repo.rollback(:storage_unavailable)
        end

      {:error, _changeset} ->
        Repo.rollback(:invalid_schedule)
    end
  end

  defp valid_execution_input?(
         trigger_id,
         expected_next_run_at,
         executed_at,
         next_run_at,
         local_date
       ) do
    valid_storage_datetime?(expected_next_run_at) and
      valid_storage_datetime?(executed_at) and
      valid_storage_datetime?(next_run_at) and
      valid_storage_date?(local_date) and
      StochasticSchedule.changeset(%StochasticSchedule{}, %{
        trigger_id: trigger_id,
        last_run_at: executed_at,
        next_run_at: next_run_at,
        daily_count: 0,
        daily_count_date: local_date
      }).valid?
  end

  defp record_execution_transaction(
         trigger_id,
         expected_next_run_at,
         executed_at,
         next_run_at,
         local_date
       ) do
    result =
      Repo.transaction(fn ->
        update_execution(
          trigger_id,
          expected_next_run_at,
          executed_at,
          next_run_at,
          local_date
        )
      end)

    case result do
      {:ok, %StochasticSchedule{} = schedule} ->
        {:ok, schedule}

      {:error, reason}
      when reason in [:daily_limit_reached, :invalid_schedule, :schedule_conflict] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp update_execution(
         trigger_id,
         expected_next_run_at,
         executed_at,
         next_run_at,
         local_date
       ) do
    case Repo.get(StochasticSchedule, trigger_id) do
      %StochasticSchedule{} = schedule ->
        if due_version?(schedule, expected_next_run_at, executed_at) do
          persist_execution(schedule, executed_at, next_run_at, local_date)
        else
          Repo.rollback(:schedule_conflict)
        end

      nil ->
        Repo.rollback(:schedule_conflict)
    end
  end

  defp due_version?(schedule, expected_next_run_at, executed_at) do
    DateTime.compare(schedule.next_run_at, expected_next_run_at) == :eq and
      DateTime.compare(expected_next_run_at, executed_at) in [:lt, :eq]
  end

  defp persist_execution(schedule, executed_at, next_run_at, local_date) do
    with {:ok, daily_count, daily_count_date} <- next_daily_state(schedule, local_date),
         {:ok, updated} <-
           schedule
           |> StochasticSchedule.changeset(%{
             last_run_at: executed_at,
             next_run_at: next_run_at,
             daily_count: daily_count,
             daily_count_date: daily_count_date
           })
           |> Repo.update() do
      updated
    else
      {:error, :daily_limit_reached} -> Repo.rollback(:daily_limit_reached)
      {:error, _changeset} -> Repo.rollback(:invalid_schedule)
    end
  end

  defp next_daily_state(_schedule, nil), do: {:ok, 0, nil}

  defp next_daily_state(
         %StochasticSchedule{daily_count: count, daily_count_date: local_date},
         local_date
       )
       when count < @max_daily_count,
       do: {:ok, count + 1, local_date}

  defp next_daily_state(
         %StochasticSchedule{daily_count: @max_daily_count, daily_count_date: local_date},
         local_date
       ),
       do: {:error, :daily_limit_reached}

  defp next_daily_state(_schedule, local_date), do: {:ok, 1, local_date}

  defp valid_storage_datetime?(%DateTime{time_zone: "Etc/UTC", year: year} = datetime)
       when year in 0..9999,
       do: DateTimeValidator.validate(datetime) == :ok

  defp valid_storage_datetime?(_datetime), do: false

  defp valid_storage_date?(nil), do: true

  defp valid_storage_date?(
         %Date{calendar: Calendar.ISO, year: year, month: month, day: day} = date
       )
       when year in 0..9999 and is_integer(month) and is_integer(day) do
    case Date.new(year, month, day) do
      {:ok, canonical} -> canonical == date
      _failure -> false
    end
  end

  defp valid_storage_date?(_date), do: false
end

defmodule ClusterMurmur.Persistence.StochasticScheduleStore do
  @moduledoc """
  Restores, retires, discovers, and claims stochastic schedule state.

  Existing durable state always wins over a newly calculated initial run. Due
  schedules can be claimed through a fixed bounded lease, and only that opaque
  claim can authorize the corresponding completion or deferral update. Random
  sampling remains outside this store. Retirement accepts only one bounded
  active-trigger allowlist and deletes one bounded page.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Config.Value
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{
    StochasticSchedule,
    StochasticScheduleClaim,
    StochasticScheduleRetirement
  }

  alias ClusterMurmur.Repo

  @claim_lease_seconds 60
  @claim_token_bytes 32
  @max_due_schedules 100
  @max_daily_count 10_000
  @max_active_trigger_ids 256
  @retirement_page_size 100

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
    if valid_storage_datetime?(next_run_at) do
      changeset =
        StochasticSchedule.changeset(%StochasticSchedule{}, %{
          trigger_id: trigger_id,
          next_run_at: next_run_at
        })

      if changeset.valid?,
        do: persist(changeset, trigger_id),
        else: {:error, :invalid_schedule}
    else
      {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Retires at most 100 schedules absent from one configured trigger set."
  @spec retire_unconfigured(term()) ::
          {:ok, StochasticScheduleRetirement.t()} | {:error, error()}
  def retire_unconfigured(active_trigger_ids) do
    with {:ok, active_trigger_ids} <- validate_active_trigger_ids(active_trigger_ids) do
      persist_retirement(active_trigger_ids)
    else
      _failure -> {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Claims one due schedule through a fixed 60-second opaque lease."
  @spec claim_due(term(), term(), term()) ::
          {:ok, StochasticScheduleClaim.t()} | {:error, error()}
  def claim_due(trigger_id, expected_next_run_at, claimed_at) do
    with true <- valid_claim_input?(trigger_id, expected_next_run_at, claimed_at),
         {:ok, expires_at} <- claim_expiry(claimed_at) do
      token = generate_claim_token()
      claim_due_transaction(trigger_id, expected_next_run_at, claimed_at, expires_at, token)
    else
      _invalid -> {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Records one claimed execution and its next run in one transaction."
  @spec record_execution(term(), term(), term(), term(), term()) ::
          {:ok, StochasticSchedule.t()} | {:error, error()}
  def record_execution(claim, executed_at, recorded_at, next_run_at, local_date) do
    if valid_execution_input?(claim, executed_at, recorded_at, next_run_at, local_date) do
      record_execution_transaction(claim, executed_at, recorded_at, next_run_at, local_date)
    else
      {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Moves one claimed, unexecuted schedule to an already sampled future run."
  @spec reschedule(term(), term(), term()) ::
          {:ok, StochasticSchedule.t()} | {:error, error()}
  def reschedule(claim, rescheduled_at, next_run_at) do
    if valid_reschedule_input?(claim, rescheduled_at, next_run_at) do
      reschedule_transaction(claim, rescheduled_at, next_run_at)
    else
      {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Returns the first page of at most 100 schedules due at one UTC instant."
  @spec list_due(term()) :: {:ok, [StochasticSchedule.t()]} | {:error, error()}
  def list_due(now) do
    if valid_storage_datetime?(now),
      do: list_due_query(now, nil),
      else: {:error, :invalid_datetime}
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Returns the next due page strictly after one `(next_run_at, trigger_id)` cursor."
  @spec list_due_after(term(), term()) ::
          {:ok, [StochasticSchedule.t()]} | {:error, error()}
  def list_due_after(now, {next_run_at, trigger_id} = cursor) do
    cond do
      not valid_storage_datetime?(now) -> {:error, :invalid_datetime}
      not valid_due_cursor?(next_run_at, trigger_id) -> {:error, :invalid_schedule}
      true -> list_due_query(now, cursor)
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def list_due_after(now, _cursor) do
    if valid_storage_datetime?(now),
      do: {:error, :invalid_schedule},
      else: {:error, :invalid_datetime}
  end

  defp list_due_query(now, cursor) do
    query =
      from schedule in StochasticSchedule,
        where:
          schedule.next_run_at <= ^now and
            (is_nil(schedule.claim_token) or schedule.claim_expires_at <= ^now),
        order_by: [asc: schedule.next_run_at, asc: schedule.trigger_id],
        limit: @max_due_schedules,
        select:
          struct(schedule, [
            :trigger_id,
            :next_run_at,
            :last_run_at,
            :daily_count,
            :daily_count_date
          ])

    query = apply_due_cursor(query, cursor)
    {:ok, Repo.all(query)}
  end

  defp apply_due_cursor(query, nil), do: query

  defp apply_due_cursor(query, {next_run_at, trigger_id}) do
    from schedule in query,
      where:
        schedule.next_run_at > ^next_run_at or
          (schedule.next_run_at == ^next_run_at and schedule.trigger_id > ^trigger_id)
  end

  defp valid_due_cursor?(next_run_at, trigger_id) do
    valid_storage_datetime?(next_run_at) and
      StochasticSchedule.changeset(%StochasticSchedule{}, %{
        trigger_id: trigger_id,
        next_run_at: next_run_at,
        daily_count: 0
      }).valid?
  end

  defp persist(changeset, trigger_id) do
    case Repo.transaction(fn -> insert_then_restore(changeset, trigger_id) end) do
      {:ok, %StochasticSchedule{} = schedule} -> {:ok, omit_claim(schedule)}
      {:error, :invalid_schedule} -> {:error, :invalid_schedule}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp persist_retirement(active_trigger_ids) do
    case Repo.transaction(fn -> retire_page(active_trigger_ids) end, mode: :immediate) do
      {:ok, %StochasticScheduleRetirement{} = result} -> {:ok, result}
      {:error, :invalid_schedule} -> {:error, :invalid_schedule}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp retire_page(active_trigger_ids) do
    query =
      from schedule in StochasticSchedule,
        order_by: [asc: schedule.trigger_id],
        limit: @retirement_page_size + 1,
        select: schedule.trigger_id

    stale_ids =
      if active_trigger_ids == [],
        do: Repo.all(query),
        else:
          Repo.all(from schedule in query, where: schedule.trigger_id not in ^active_trigger_ids)

    with :ok <- validate_stale_ids(stale_ids),
         retired_ids = Enum.take(stale_ids, @retirement_page_size),
         :ok <- delete_retired_ids(retired_ids) do
      %StochasticScheduleRetirement{
        retired_count: length(retired_ids),
        saturated?: length(stale_ids) > @retirement_page_size
      }
    else
      _failure -> Repo.rollback(:invalid_schedule)
    end
  end

  defp delete_retired_ids([]), do: :ok

  defp delete_retired_ids(retired_ids) do
    query = from schedule in StochasticSchedule, where: schedule.trigger_id in ^retired_ids

    case Repo.delete_all(query) do
      {count, nil} when count == length(retired_ids) -> :ok
      _failure -> {:error, :invalid_schedule}
    end
  end

  defp validate_active_trigger_ids(trigger_ids) when is_list(trigger_ids),
    do: validate_trigger_ids(trigger_ids, %{}, 0, @max_active_trigger_ids)

  defp validate_active_trigger_ids(_trigger_ids), do: {:error, :invalid_schedule}

  defp validate_trigger_ids([], _seen, _count, _maximum), do: {:ok, []}

  defp validate_trigger_ids([trigger_id | rest], seen, count, maximum) when count < maximum do
    with {:ok, ^trigger_id} <- Value.id(trigger_id),
         false <- Map.has_key?(seen, trigger_id),
         {:ok, validated_rest} <-
           validate_trigger_ids(rest, Map.put(seen, trigger_id, true), count + 1, maximum) do
      {:ok, [trigger_id | validated_rest]}
    else
      _failure -> {:error, :invalid_schedule}
    end
  end

  defp validate_trigger_ids(_trigger_ids, _seen, _count, _maximum),
    do: {:error, :invalid_schedule}

  defp validate_stale_ids(stale_ids) when is_list(stale_ids) do
    case validate_trigger_ids(stale_ids, %{}, 0, @retirement_page_size + 1) do
      {:ok, ^stale_ids} -> :ok
      _failure -> {:error, :invalid_schedule}
    end
  end

  defp validate_stale_ids(_stale_ids), do: {:error, :invalid_schedule}

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
         %StochasticScheduleClaim{} = claim,
         executed_at,
         recorded_at,
         next_run_at,
         local_date
       ) do
    valid_claim?(claim) and
      valid_storage_datetime?(executed_at) and
      valid_storage_datetime?(recorded_at) and
      valid_storage_datetime?(next_run_at) and
      valid_storage_date?(local_date) and
      StochasticSchedule.changeset(%StochasticSchedule{}, %{
        trigger_id: claim.trigger_id,
        last_run_at: executed_at,
        next_run_at: next_run_at,
        daily_count: 0,
        daily_count_date: local_date
      }).valid?
  end

  defp valid_execution_input?(_claim, _executed_at, _recorded_at, _next_run_at, _local_date),
    do: false

  defp valid_reschedule_input?(%StochasticScheduleClaim{} = claim, rescheduled_at, next_run_at) do
    valid_claim?(claim) and valid_storage_datetime?(rescheduled_at) and
      valid_storage_datetime?(next_run_at) and
      DateTime.compare(next_run_at, rescheduled_at) == :gt
  end

  defp valid_reschedule_input?(_claim, _rescheduled_at, _next_run_at), do: false

  defp record_execution_transaction(claim, executed_at, recorded_at, next_run_at, local_date) do
    result =
      Repo.transaction(fn ->
        update_execution(claim, executed_at, recorded_at, next_run_at, local_date)
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

  defp reschedule_transaction(claim, rescheduled_at, next_run_at) do
    result =
      Repo.transaction(fn ->
        query =
          from schedule in StochasticSchedule,
            where:
              schedule.trigger_id == ^claim.trigger_id and
                schedule.next_run_at == ^claim.expected_next_run_at and
                schedule.claim_token == ^claim.token

        case Repo.one(query) do
          %StochasticSchedule{} = schedule ->
            if claimed_for_reschedule?(schedule, claim, rescheduled_at) do
              persist_reschedule(schedule, next_run_at)
            else
              Repo.rollback(:schedule_conflict)
            end

          nil ->
            Repo.rollback(:schedule_conflict)
        end
      end)

    case result do
      {:ok, %StochasticSchedule{} = schedule} -> {:ok, schedule}
      {:error, :invalid_schedule} -> {:error, :invalid_schedule}
      {:error, :schedule_conflict} -> {:error, :schedule_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp update_execution(claim, executed_at, recorded_at, next_run_at, local_date) do
    query =
      from schedule in StochasticSchedule,
        where:
          schedule.trigger_id == ^claim.trigger_id and
            schedule.next_run_at == ^claim.expected_next_run_at and
            schedule.claim_token == ^claim.token

    case Repo.one(query) do
      %StochasticSchedule{} = schedule ->
        if claimed_version?(schedule, claim, executed_at, recorded_at) do
          persist_execution(schedule, executed_at, next_run_at, local_date)
        else
          Repo.rollback(:schedule_conflict)
        end

      nil ->
        Repo.rollback(:schedule_conflict)
    end
  end

  defp claimed_version?(schedule, claim, executed_at, recorded_at) do
    DateTime.compare(claim.expected_next_run_at, claim.started_at) in [:lt, :eq] and
      DateTime.compare(claim.started_at, executed_at) in [:lt, :eq] and
      DateTime.compare(executed_at, recorded_at) in [:lt, :eq] and
      DateTime.compare(recorded_at, claim.expires_at) == :lt and
      DateTime.compare(schedule.claim_started_at, claim.started_at) == :eq and
      DateTime.compare(schedule.claim_expires_at, claim.expires_at) == :eq
  end

  defp claimed_for_reschedule?(schedule, claim, rescheduled_at) do
    DateTime.compare(claim.expected_next_run_at, claim.started_at) in [:lt, :eq] and
      DateTime.compare(claim.started_at, rescheduled_at) in [:lt, :eq] and
      DateTime.compare(rescheduled_at, claim.expires_at) == :lt and
      DateTime.compare(schedule.claim_started_at, claim.started_at) == :eq and
      DateTime.compare(schedule.claim_expires_at, claim.expires_at) == :eq
  end

  defp persist_reschedule(schedule, next_run_at) do
    case schedule
         |> StochasticSchedule.changeset(%{
           next_run_at: next_run_at,
           claim_token: nil,
           claim_started_at: nil,
           claim_expires_at: nil
         })
         |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> Repo.rollback(:invalid_schedule)
    end
  end

  defp persist_execution(schedule, executed_at, next_run_at, local_date) do
    with {:ok, daily_count, daily_count_date} <- next_daily_state(schedule, local_date),
         {:ok, updated} <-
           schedule
           |> StochasticSchedule.changeset(%{
             last_run_at: executed_at,
             next_run_at: next_run_at,
             daily_count: daily_count,
             daily_count_date: daily_count_date,
             claim_token: nil,
             claim_started_at: nil,
             claim_expires_at: nil
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

  defp valid_claim_input?(trigger_id, expected_next_run_at, claimed_at) do
    valid_storage_datetime?(expected_next_run_at) and
      valid_storage_datetime?(claimed_at) and
      StochasticSchedule.changeset(%StochasticSchedule{}, %{
        trigger_id: trigger_id,
        next_run_at: expected_next_run_at,
        daily_count: 0
      }).valid?
  end

  defp claim_expiry(claimed_at) do
    expires_at = DateTime.add(claimed_at, @claim_lease_seconds, :second)
    if valid_storage_datetime?(expires_at), do: {:ok, expires_at}, else: :error
  end

  defp generate_claim_token do
    @claim_token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp claim_due_transaction(trigger_id, expected_next_run_at, claimed_at, expires_at, token) do
    result =
      Repo.transaction(fn ->
        query =
          from schedule in StochasticSchedule,
            where:
              schedule.trigger_id == ^trigger_id and
                schedule.next_run_at == ^expected_next_run_at and
                schedule.next_run_at <= ^claimed_at and
                (is_nil(schedule.claim_token) or schedule.claim_expires_at <= ^claimed_at)

        case Repo.update_all(query,
               set: [
                 claim_token: token,
                 claim_started_at: claimed_at,
                 claim_expires_at: expires_at
               ]
             ) do
          {1, nil} ->
            %StochasticScheduleClaim{
              trigger_id: trigger_id,
              expected_next_run_at: expected_next_run_at,
              token: token,
              started_at: claimed_at,
              expires_at: expires_at
            }

          _not_claimed ->
            Repo.rollback(:schedule_conflict)
        end
      end)

    case result do
      {:ok, %StochasticScheduleClaim{} = claim} -> {:ok, claim}
      {:error, :schedule_conflict} -> {:error, :schedule_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp valid_claim?(%StochasticScheduleClaim{} = claim) do
    valid_storage_datetime?(claim.expected_next_run_at) and
      valid_storage_datetime?(claim.started_at) and
      valid_storage_datetime?(claim.expires_at) and
      valid_claim_token?(claim.token) and
      StochasticSchedule.changeset(%StochasticSchedule{}, %{
        trigger_id: claim.trigger_id,
        next_run_at: claim.expected_next_run_at,
        daily_count: 0
      }).valid?
  end

  defp valid_claim_token?(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == @claim_token_bytes
      :error -> false
    end
  end

  defp valid_claim_token?(_token), do: false

  defp omit_claim(%StochasticSchedule{} = schedule) do
    %{schedule | claim_token: nil, claim_started_at: nil, claim_expires_at: nil}
  end

  defp valid_storage_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

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

defmodule ClusterMurmur.Persistence.StochasticScheduleStore do
  @moduledoc """
  Restores or initializes stochastic schedule state through one bounded store API.

  Existing durable state always wins over a newly calculated initial run. Due
  schedules can be claimed through a fixed bounded lease, and only that opaque
  claim can authorize the corresponding completion update. Action execution and
  resampling remain outside this store.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.{StochasticSchedule, StochasticScheduleClaim}
  alias ClusterMurmur.Repo

  @claim_lease_seconds 60
  @claim_token_bytes 32
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

  @doc "Returns at most 100 schedules due at or before one supplied UTC instant."
  @spec list_due(term()) :: {:ok, [StochasticSchedule.t()]} | {:error, error()}
  def list_due(now) do
    if valid_storage_datetime?(now) do
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
      {:ok, %StochasticSchedule{} = schedule} -> {:ok, omit_claim(schedule)}
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

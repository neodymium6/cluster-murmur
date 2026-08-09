defmodule ClusterMurmur.Persistence.ScheduleStateStore do
  @moduledoc """
  Restores, discovers, and claims durable recurring schedule state.

  The store exposes only fixed queries and opaque 60-second claims. It does not
  calculate recurrence, execute actions, emit events, or read a clock.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.{ScheduleState, ScheduleStateClaim}
  alias ClusterMurmur.Repo

  @claim_lease_seconds 60
  @claim_token_bytes 32
  @max_due_states 100

  @type error ::
          :invalid_datetime
          | :invalid_schedule
          | :schedule_conflict
          | :storage_unavailable

  @doc "Restores an existing state or atomically inserts its initial next run."
  @spec restore_or_initialize(term(), term()) :: {:ok, ScheduleState.t()} | {:error, error()}
  def restore_or_initialize(trigger_id, next_run_at) do
    with true <- valid_schedule_version?(trigger_id, next_run_at),
         changeset =
           ScheduleState.changeset(%ScheduleState{}, %{
             trigger_id: trigger_id,
             next_run_at: next_run_at
           }),
         true <- changeset.valid? do
      persist(changeset, trigger_id)
    else
      _invalid -> {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Returns the first ordered page of at most 100 due, claimable states."
  @spec list_due(term()) :: {:ok, [ScheduleState.t()]} | {:error, error()}
  def list_due(now) do
    if valid_storage_datetime?(now),
      do: list_due_query(now, nil),
      else: {:error, :invalid_datetime}
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Returns the next due page after one `(next_run_at, trigger_id)` cursor."
  @spec list_due_after(term(), term()) :: {:ok, [ScheduleState.t()]} | {:error, error()}
  def list_due_after(now, {next_run_at, trigger_id} = cursor) do
    cond do
      not valid_storage_datetime?(now) -> {:error, :invalid_datetime}
      not valid_schedule_version?(trigger_id, next_run_at) -> {:error, :invalid_schedule}
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

  @doc "Claims one exact due state through an opaque fixed 60-second lease."
  @spec claim_due(term(), term(), term()) :: {:ok, ScheduleStateClaim.t()} | {:error, error()}
  def claim_due(trigger_id, expected_next_run_at, claimed_at) do
    with true <- valid_schedule_version?(trigger_id, expected_next_run_at),
         true <- valid_storage_datetime?(claimed_at),
         {:ok, expires_at} <- claim_expiry(claimed_at) do
      token = generate_claim_token()

      claim_due_transaction(
        trigger_id,
        expected_next_run_at,
        claimed_at,
        expires_at,
        token
      )
    else
      _invalid -> {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp persist(changeset, trigger_id) do
    result =
      Repo.transaction(fn -> insert_then_restore(changeset, trigger_id) end, mode: :immediate)

    case result do
      {:ok, %ScheduleState{} = state} -> {:ok, omit_claim(state)}
      {:error, :invalid_schedule} -> {:error, :invalid_schedule}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp insert_then_restore(changeset, trigger_id) do
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:trigger_id]) do
      {:ok, _inserted_or_conflicted} ->
        case Repo.get(ScheduleState, trigger_id) do
          %ScheduleState{} = state ->
            if valid_loaded_state?(state), do: state, else: Repo.rollback(:storage_unavailable)

          nil ->
            Repo.rollback(:storage_unavailable)
        end

      {:error, _changeset} ->
        Repo.rollback(:invalid_schedule)
    end
  end

  defp list_due_query(now, cursor) do
    query =
      from state in ScheduleState,
        where:
          state.next_run_at <= ^now and
            (is_nil(state.claim_token) or state.claim_expires_at <= ^now),
        order_by: [asc: state.next_run_at, asc: state.trigger_id],
        limit: @max_due_states,
        select: struct(state, [:trigger_id, :next_run_at, :last_run_at])

    states = query |> apply_due_cursor(cursor) |> Repo.all()

    if Enum.all?(states, &valid_loaded_state?/1),
      do: {:ok, states},
      else: {:error, :storage_unavailable}
  end

  defp apply_due_cursor(query, nil), do: query

  defp apply_due_cursor(query, {next_run_at, trigger_id}) do
    from state in query,
      where:
        state.next_run_at > ^next_run_at or
          (state.next_run_at == ^next_run_at and state.trigger_id > ^trigger_id)
  end

  defp claim_due_transaction(trigger_id, expected_next_run_at, claimed_at, expires_at, token) do
    result =
      Repo.transaction(
        fn ->
          query =
            from state in ScheduleState,
              where:
                state.trigger_id == ^trigger_id and
                  state.next_run_at == ^expected_next_run_at and
                  state.next_run_at <= ^claimed_at and
                  (is_nil(state.claim_token) or state.claim_expires_at <= ^claimed_at)

          case Repo.update_all(query,
                 set: [
                   claim_token: token,
                   claim_started_at: claimed_at,
                   claim_expires_at: expires_at
                 ]
               ) do
            {1, nil} ->
              %ScheduleStateClaim{
                trigger_id: trigger_id,
                expected_next_run_at: expected_next_run_at,
                token: token,
                started_at: claimed_at,
                expires_at: expires_at
              }

            _not_claimed ->
              Repo.rollback(:schedule_conflict)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, %ScheduleStateClaim{} = claim} -> {:ok, claim}
      {:error, :schedule_conflict} -> {:error, :schedule_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp valid_schedule_version?(trigger_id, next_run_at) do
    valid_storage_datetime?(next_run_at) and
      ScheduleState.changeset(%ScheduleState{}, %{
        trigger_id: trigger_id,
        next_run_at: next_run_at
      }).valid?
  end

  defp valid_loaded_state?(%ScheduleState{} = state),
    do: ScheduleState.changeset(state, %{}).valid?

  defp valid_loaded_state?(_state), do: false

  defp claim_expiry(claimed_at) do
    expires_at = DateTime.add(claimed_at, @claim_lease_seconds, :second)
    if valid_storage_datetime?(expires_at), do: {:ok, expires_at}, else: :error
  end

  defp generate_claim_token do
    @claim_token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp omit_claim(%ScheduleState{} = state) do
    %{state | claim_token: nil, claim_started_at: nil, claim_expires_at: nil}
  end

  defp valid_storage_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok
end

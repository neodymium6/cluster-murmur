defmodule ClusterMurmur.Persistence.StochasticScheduleStore do
  @moduledoc """
  Restores or initializes stochastic schedule state through one bounded store API.

  Existing durable state always wins over a newly calculated initial run. Due
  claiming, resampling, and execution bookkeeping belong to later store
  operations with their own transaction contracts.
  """

  alias ClusterMurmur.Persistence.StochasticSchedule
  alias ClusterMurmur.Repo

  @type error :: :invalid_schedule | :storage_unavailable

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
end

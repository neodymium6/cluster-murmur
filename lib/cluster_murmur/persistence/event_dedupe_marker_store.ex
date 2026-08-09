defmodule ClusterMurmur.Persistence.EventDedupeMarkerStore do
  @moduledoc """
  Prunes expired event dedupe markers through one bounded store operation.

  The store accepts only an exact pure retention plan and deletes no more than
  one fixed batch. It returns only an aggregate count and never exposes marker
  keys, event identifiers, or timestamps.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Events.RetentionPlanner
  alias ClusterMurmur.Events.RetentionPlanner.Plan
  alias ClusterMurmur.Persistence.EventDedupeMarker
  alias ClusterMurmur.Repo

  @max_pruned 100

  @type error :: :invalid_retention_plan | :storage_unavailable

  @doc "Deletes at most 100 markers accepted at or before the exact retention cutoff."
  @spec prune(term()) :: {:ok, 0..100} | {:error, error()}
  def prune(%Plan{} = plan) do
    case RetentionPlanner.validate(plan) do
      :ok -> prune_batch(plan.cutoff)
      {:error, :invalid_retention_plan} -> {:error, :invalid_retention_plan}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def prune(_plan), do: {:error, :invalid_retention_plan}

  defp prune_batch(cutoff) do
    candidate_keys =
      from marker in EventDedupeMarker,
        where: marker.accepted_at <= ^cutoff,
        order_by: [asc: marker.accepted_at, asc: marker.dedupe_key],
        limit: @max_pruned,
        select: marker.dedupe_key

    query =
      from marker in EventDedupeMarker,
        where: marker.dedupe_key in subquery(candidate_keys)

    case Repo.delete_all(query) do
      {count, nil} when count in 0..@max_pruned -> {:ok, count}
      _failure -> {:error, :storage_unavailable}
    end
  end
end

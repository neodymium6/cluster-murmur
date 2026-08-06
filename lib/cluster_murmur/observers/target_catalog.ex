defmodule ClusterMurmur.Observers.TargetCatalog do
  @moduledoc """
  Bounds and normalizes target identities returned by a read-only observer.

  The catalog rejects duplicate or malformed targets before any observation
  call and orders accepted identities deterministically. It performs no
  transport call, observation ingestion, or concurrent work.
  """

  alias ClusterMurmur.Observers.Target

  @max_targets 256
  @max_total_id_bytes 64 * 1_024
  @catalog_keys [:__struct__, :targets]
  @catalog_key_count length(@catalog_keys)

  @derive {Inspect, only: []}
  @enforce_keys [:targets]
  defstruct [:targets]

  @type t :: %__MODULE__{targets: [Target.t()]}
  @type error :: :invalid_observer_targets

  @doc "Normalizes one bounded adapter target list into stable ID order."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(targets) when is_list(targets) do
    case collect(targets, MapSet.new(), [], 0, 0) do
      {:ok, normalized} ->
        catalog = %__MODULE__{targets: Enum.sort_by(normalized, & &1.id)}

        case validate(catalog) do
          :ok -> {:ok, catalog}
          {:error, :invalid_observer_targets} = error -> error
        end

      {:error, :invalid_observer_targets} = error ->
        error
    end
  rescue
    _error -> {:error, :invalid_observer_targets}
  catch
    _kind, _reason -> {:error, :invalid_observer_targets}
  end

  def parse(_targets), do: {:error, :invalid_observer_targets}

  @doc "Revalidates one exact normalized target catalog."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = catalog) do
    with true <- exact_catalog?(catalog),
         {:ok, ids} <- validate_targets(catalog.targets, MapSet.new(), [], 0, 0),
         true <- ids == Enum.sort(ids) do
      :ok
    else
      _failure -> {:error, :invalid_observer_targets}
    end
  rescue
    _error -> {:error, :invalid_observer_targets}
  catch
    _kind, _reason -> {:error, :invalid_observer_targets}
  end

  def validate(_catalog), do: {:error, :invalid_observer_targets}

  defp collect([], _seen, targets, _count, _bytes), do: {:ok, Enum.reverse(targets)}

  defp collect([raw | remaining], seen, targets, count, bytes) when count < @max_targets do
    with {:ok, target} <- Target.parse(raw),
         false <- MapSet.member?(seen, target.id),
         next_bytes = bytes + byte_size(target.id),
         true <- next_bytes <= @max_total_id_bytes do
      collect(
        remaining,
        MapSet.put(seen, target.id),
        [target | targets],
        count + 1,
        next_bytes
      )
    else
      _failure -> {:error, :invalid_observer_targets}
    end
  end

  defp collect(_targets, _seen, _normalized, _count, _bytes),
    do: {:error, :invalid_observer_targets}

  defp validate_targets([], _seen, ids, _count, _bytes), do: {:ok, Enum.reverse(ids)}

  defp validate_targets([target | remaining], seen, ids, count, bytes)
       when count < @max_targets do
    with :ok <- Target.validate(target),
         false <- MapSet.member?(seen, target.id),
         next_bytes = bytes + byte_size(target.id),
         true <- next_bytes <= @max_total_id_bytes do
      validate_targets(
        remaining,
        MapSet.put(seen, target.id),
        [target.id | ids],
        count + 1,
        next_bytes
      )
    else
      _failure -> {:error, :invalid_observer_targets}
    end
  end

  defp validate_targets(_targets, _seen, _ids, _count, _bytes),
    do: {:error, :invalid_observer_targets}

  defp exact_catalog?(catalog) do
    map_size(catalog) == @catalog_key_count and
      Enum.all?(@catalog_keys, &Map.has_key?(catalog, &1))
  end
end

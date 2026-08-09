defmodule ClusterMurmur.Personas.StarterSelector do
  @moduledoc """
  Selects at most one starter from bounded redacted candidate projections.

  Empty and zero-total projections do not sample. A sole positive candidate is
  selected directly. Only the final weighted choice among multiple positive
  candidates is delegated to an injected random adapter.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.StarterCandidateValidator

  @max_candidates 256
  @max_float DomainLimits.max_float()

  @type error ::
          :duplicate_starter_candidate
          | :invalid_candidate_weight
          | :invalid_random_source
          | :invalid_random_value
          | :invalid_starter_candidate
          | :too_many_starter_candidates

  @doc "Selects one persona ID, or returns `:none` when no positive choice exists."
  @spec select(term(), module()) :: {:ok, String.t()} | :none | {:error, error()}
  def select(candidates, random) do
    with {:ok, candidates} <- validate_candidates(candidates),
         {:ok, _total} <- total_weight(candidates) do
      candidates
      |> Enum.filter(&(&1.weight > 0))
      |> select_positive(random)
    end
  rescue
    _error -> {:error, :invalid_starter_candidate}
  catch
    _kind, _reason -> {:error, :invalid_starter_candidate}
  end

  defp validate_candidates(candidates) when is_list(candidates),
    do: validate_candidates(candidates, %{}, [], 0)

  defp validate_candidates(_candidates), do: {:error, :invalid_starter_candidate}

  defp validate_candidates([], _seen, validated, _count),
    do: {:ok, Enum.sort_by(validated, & &1.persona_id)}

  defp validate_candidates([_candidate | _remaining], _seen, _validated, @max_candidates),
    do: {:error, :too_many_starter_candidates}

  defp validate_candidates([candidate | remaining], seen, validated, count) do
    with :ok <- StarterCandidateValidator.validate(candidate),
         false <- Map.has_key?(seen, candidate.persona_id) do
      validate_candidates(
        remaining,
        Map.put(seen, candidate.persona_id, true),
        [candidate | validated],
        count + 1
      )
    else
      true -> {:error, :duplicate_starter_candidate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_candidates(_improper_tail, _seen, _validated, _count),
    do: {:error, :invalid_starter_candidate}

  defp total_weight(candidates) do
    Enum.reduce_while(candidates, {:ok, 0}, fn candidate, {:ok, total} ->
      case add_weight(total, candidate.weight) do
        {:ok, total} -> {:cont, {:ok, total}}
        {:error, :invalid_candidate_weight} = error -> {:halt, error}
      end
    end)
  end

  defp add_weight(total, weight) do
    combined = total + weight

    if valid_weight?(combined),
      do: {:ok, combined},
      else: {:error, :invalid_candidate_weight}
  rescue
    _error -> {:error, :invalid_candidate_weight}
  end

  defp select_positive([], _random), do: :none
  defp select_positive([candidate], _random), do: {:ok, candidate.persona_id}

  defp select_positive(candidates, random) do
    weighted = Enum.map(candidates, &{&1.persona_id, &1.weight})
    sample(weighted, MapSet.new(candidates, & &1.persona_id), random)
  end

  defp sample(weighted, persona_ids, random) when is_atom(random) do
    if Code.ensure_loaded(random) == {:module, random} and
         function_exported?(random, :weighted_choice, 1) do
      case random.weighted_choice(weighted) do
        {:ok, persona_id} ->
          if MapSet.member?(persona_ids, persona_id),
            do: {:ok, persona_id},
            else: {:error, :invalid_random_value}

        :empty ->
          {:error, :invalid_random_value}

        _value ->
          {:error, :invalid_random_value}
      end
    else
      {:error, :invalid_random_source}
    end
  rescue
    _error -> {:error, :invalid_random_source}
  catch
    _kind, _reason -> {:error, :invalid_random_source}
  end

  defp sample(_weighted, _persona_ids, _random), do: {:error, :invalid_random_source}

  defp valid_weight?(weight) when is_integer(weight),
    do: weight >= 0 and weight <= @max_float

  defp valid_weight?(weight) when is_float(weight),
    do: weight == weight and weight >= 0 and weight <= @max_float
end

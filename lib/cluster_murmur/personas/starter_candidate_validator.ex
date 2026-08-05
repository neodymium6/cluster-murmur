defmodule ClusterMurmur.Personas.StarterCandidateValidator do
  @moduledoc """
  Validates one exact redacted starter-candidate projection.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.StarterCandidate

  @candidate_keys StarterCandidate.__struct__() |> Map.keys()
  @candidate_key_count length(@candidate_keys)
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_float DomainLimits.max_float()

  @type error :: :invalid_candidate_weight | :invalid_starter_candidate

  @doc "Validates one complete starter-candidate runtime value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%StarterCandidate{} = candidate) do
    with true <- exact_candidate?(candidate),
         true <- valid_id?(candidate.persona_id),
         true <- valid_weight?(candidate.binding_weight),
         true <- valid_weight?(candidate.interest_weight),
         true <- valid_weight?(candidate.spontaneous_weight),
         true <- valid_weight?(candidate.weight),
         {:ok, total} <-
           total_weight(
             candidate.binding_weight,
             candidate.interest_weight,
             candidate.spontaneous_weight
           ),
         true <- candidate.weight == total do
      :ok
    else
      {:error, :invalid_candidate_weight} -> {:error, :invalid_candidate_weight}
      false -> {:error, :invalid_starter_candidate}
    end
  rescue
    _error -> {:error, :invalid_starter_candidate}
  catch
    _kind, _reason -> {:error, :invalid_starter_candidate}
  end

  def validate(_candidate), do: {:error, :invalid_starter_candidate}

  defp exact_candidate?(candidate) do
    map_size(candidate) == @candidate_key_count and
      Enum.all?(@candidate_keys, &Map.has_key?(candidate, &1))
  end

  defp valid_id?(value) when is_binary(value) and byte_size(value) in 1..@max_id_bytes,
    do: String.valid?(value) and Regex.match?(@id_pattern, value)

  defp valid_id?(_value), do: false

  defp total_weight(binding_weight, interest_weight, spontaneous_weight) do
    total = binding_weight + interest_weight + spontaneous_weight

    if valid_weight?(total),
      do: {:ok, total},
      else: {:error, :invalid_candidate_weight}
  rescue
    _error -> {:error, :invalid_candidate_weight}
  end

  defp valid_weight?(weight) when is_integer(weight),
    do: weight >= 0 and weight <= @max_float

  defp valid_weight?(weight) when is_float(weight),
    do: weight == weight and weight >= 0 and weight <= @max_float

  defp valid_weight?(_weight), do: false
end

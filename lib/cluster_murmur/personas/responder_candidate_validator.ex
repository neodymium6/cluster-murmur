defmodule ClusterMurmur.Personas.ResponderCandidateValidator do
  @moduledoc """
  Validates one exact redacted responder-candidate projection.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.ResponderCandidate

  @candidate_keys ResponderCandidate.__struct__() |> Map.keys()
  @candidate_key_count length(@candidate_keys)
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_float DomainLimits.max_float()

  @type error :: :invalid_candidate_weight | :invalid_responder_candidate

  @doc "Validates one complete responder-candidate runtime value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%ResponderCandidate{} = candidate) do
    with true <- exact_candidate?(candidate),
         true <- valid_id?(candidate.persona_id),
         true <- valid_weight?(candidate.binding_weight),
         true <- valid_weight?(candidate.interest_weight),
         true <- valid_weight?(candidate.relationship_weight),
         true <- valid_weight?(candidate.reply_weight),
         true <- valid_weight?(candidate.weight),
         {:ok, total} <- total_weight(candidate),
         true <- candidate.weight == total do
      :ok
    else
      {:error, :invalid_candidate_weight} -> {:error, :invalid_candidate_weight}
      false -> {:error, :invalid_responder_candidate}
    end
  rescue
    _error -> {:error, :invalid_responder_candidate}
  catch
    _kind, _reason -> {:error, :invalid_responder_candidate}
  end

  def validate(_candidate), do: {:error, :invalid_responder_candidate}

  defp exact_candidate?(candidate) do
    map_size(candidate) == @candidate_key_count and
      Enum.all?(@candidate_keys, &Map.has_key?(candidate, &1))
  end

  defp total_weight(candidate) do
    total =
      candidate.binding_weight + candidate.interest_weight + candidate.relationship_weight +
        candidate.reply_weight

    if valid_weight?(total),
      do: {:ok, total},
      else: {:error, :invalid_candidate_weight}
  rescue
    _error -> {:error, :invalid_candidate_weight}
  end

  defp valid_id?(value) when is_binary(value) and byte_size(value) in 1..@max_id_bytes,
    do: String.valid?(value) and Regex.match?(@id_pattern, value)

  defp valid_id?(_value), do: false

  defp valid_weight?(weight) when is_integer(weight),
    do: weight >= 0 and weight <= @max_float

  defp valid_weight?(weight) when is_float(weight),
    do: weight == weight and weight >= 0 and weight <= @max_float

  defp valid_weight?(_weight), do: false
end

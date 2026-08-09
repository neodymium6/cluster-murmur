defmodule ClusterMurmur.Personas.BindingValidator do
  @moduledoc """
  Validates one exact bounded persona binding without exposing its values.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.Binding

  @binding_keys Binding.__struct__() |> Map.keys()
  @binding_key_count length(@binding_keys)
  @candidate_keys [:persona, :weight]
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_float DomainLimits.max_float()
  @max_candidates 256

  @type error :: :duplicate_binding_candidate | :invalid_binding | :too_many_candidates

  @doc "Validates one complete version 1 binding runtime value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%Binding{} = binding) do
    with true <- exact_binding?(binding),
         true <- valid_id?(binding.id),
         true <- valid_id?(binding.group),
         :ok <- validate_candidates(binding.candidates) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_binding}
    end
  rescue
    _error -> {:error, :invalid_binding}
  catch
    _kind, _reason -> {:error, :invalid_binding}
  end

  def validate(_binding), do: {:error, :invalid_binding}

  defp exact_binding?(binding) do
    map_size(binding) == @binding_key_count and
      Enum.all?(@binding_keys, &Map.has_key?(binding, &1))
  end

  defp validate_candidates(candidates) when is_list(candidates),
    do: validate_candidates(candidates, %{}, 0)

  defp validate_candidates(_candidates), do: {:error, :invalid_binding}

  defp validate_candidates([], _seen, 0), do: {:error, :invalid_binding}
  defp validate_candidates([], _seen, _count), do: :ok

  defp validate_candidates([_candidate | _candidates], _seen, @max_candidates),
    do: {:error, :too_many_candidates}

  defp validate_candidates([candidate | candidates], seen, count) do
    with {:ok, persona_id} <- validate_candidate(candidate),
         false <- Map.has_key?(seen, persona_id) do
      validate_candidates(candidates, Map.put(seen, persona_id, true), count + 1)
    else
      true -> {:error, :duplicate_binding_candidate}
      {:error, :invalid_binding} -> {:error, :invalid_binding}
    end
  end

  defp validate_candidates(_improper_tail, _seen, _count), do: {:error, :invalid_binding}

  defp validate_candidate(%{persona: persona_id, weight: weight} = candidate) do
    if map_size(candidate) == length(@candidate_keys) and
         Enum.all?(@candidate_keys, &Map.has_key?(candidate, &1)) and valid_id?(persona_id) and
         valid_weight?(weight),
       do: {:ok, persona_id},
       else: {:error, :invalid_binding}
  end

  defp validate_candidate(_candidate), do: {:error, :invalid_binding}

  defp valid_id?(value) when is_binary(value) and byte_size(value) in 1..@max_id_bytes,
    do: String.valid?(value) and Regex.match?(@id_pattern, value)

  defp valid_id?(_value), do: false

  defp valid_weight?(value) when is_integer(value),
    do: value >= 0 and value <= @max_float

  defp valid_weight?(value) when is_float(value),
    do: value == value and value >= 0 and value <= @max_float

  defp valid_weight?(_value), do: false
end

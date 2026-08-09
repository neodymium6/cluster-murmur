defmodule ClusterMurmur.Personas.ResponderSelector do
  @moduledoc """
  Selects one responder or an explicit no-reply outcome.

  A probability-gate no reply consumes no further inputs. A reply outcome
  validates bounded candidates, always adds configured `no_reply`, and delegates
  only a final choice among multiple positive outcomes to injected randomness.
  """

  alias ClusterMurmur.Conversations.ReplyGateDecision
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.ResponderCandidateValidator

  @decision_keys ReplyGateDecision.__struct__() |> Map.keys()
  @decision_key_count length(@decision_keys)
  @max_candidates 256
  @max_float DomainLimits.max_float()

  @type error ::
          :duplicate_responder_candidate
          | :invalid_candidate_weight
          | :invalid_no_reply_weight
          | :invalid_random_source
          | :invalid_random_value
          | :invalid_reply_gate_decision
          | :invalid_responder_candidate
          | :too_many_responder_candidates

  @type result :: {:reply, String.t()} | :no_reply

  @doc "Selects one validated reply outcome."
  @spec select(term(), term(), term(), module()) :: {:ok, result()} | {:error, error()}
  def select(decision, candidates, no_reply_weight, random) do
    with :ok <- validate_decision(decision) do
      select_gate_outcome(decision, candidates, no_reply_weight, random)
    end
  rescue
    _error -> {:error, :invalid_reply_gate_decision}
  catch
    _kind, _reason -> {:error, :invalid_reply_gate_decision}
  end

  defp validate_decision(%ReplyGateDecision{outcome: outcome} = decision)
       when outcome in [:reply, :no_reply] do
    if map_size(decision) == @decision_key_count and
         Enum.all?(@decision_keys, &Map.has_key?(decision, &1)),
       do: :ok,
       else: {:error, :invalid_reply_gate_decision}
  end

  defp validate_decision(_decision), do: {:error, :invalid_reply_gate_decision}

  defp select_gate_outcome(%ReplyGateDecision{outcome: :no_reply}, _candidates, _weight, _random),
    do: {:ok, :no_reply}

  defp select_gate_outcome(
         %ReplyGateDecision{outcome: :reply},
         candidates,
         no_reply_weight,
         random
       ) do
    with {:ok, candidates} <- validate_candidates(candidates),
         :ok <- validate_no_reply_weight(no_reply_weight),
         {:ok, _total} <- aggregate_weight(candidates, no_reply_weight) do
      candidates
      |> positive_outcomes(no_reply_weight)
      |> choose(random)
    end
  end

  defp validate_candidates(candidates) when is_list(candidates),
    do: validate_candidates(candidates, %{}, [], 0)

  defp validate_candidates(_candidates), do: {:error, :invalid_responder_candidate}

  defp validate_candidates([], _seen, validated, _count),
    do: {:ok, Enum.sort_by(validated, & &1.persona_id)}

  defp validate_candidates([_candidate | _remaining], _seen, _validated, @max_candidates),
    do: {:error, :too_many_responder_candidates}

  defp validate_candidates([candidate | remaining], seen, validated, count) do
    with :ok <- ResponderCandidateValidator.validate(candidate),
         false <- Map.has_key?(seen, candidate.persona_id) do
      validate_candidates(
        remaining,
        Map.put(seen, candidate.persona_id, true),
        [candidate | validated],
        count + 1
      )
    else
      true -> {:error, :duplicate_responder_candidate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_candidates(_improper_tail, _seen, _validated, _count),
    do: {:error, :invalid_responder_candidate}

  defp validate_no_reply_weight(weight) do
    if valid_weight?(weight) and weight > 0,
      do: :ok,
      else: {:error, :invalid_no_reply_weight}
  end

  defp aggregate_weight(candidates, no_reply_weight) do
    Enum.reduce_while(candidates, add_weight(0, no_reply_weight), fn candidate, accumulator ->
      case accumulator do
        {:ok, total} ->
          case add_weight(total, candidate.weight) do
            {:ok, total} -> {:cont, {:ok, total}}
            {:error, :invalid_candidate_weight} = error -> {:halt, error}
          end

        {:error, :invalid_candidate_weight} = error ->
          {:halt, error}
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

  defp positive_outcomes(candidates, no_reply_weight) do
    replies =
      candidates
      |> Enum.filter(&(&1.weight > 0))
      |> Enum.map(&{{:reply, &1.persona_id}, &1.weight})

    replies ++ [{:no_reply, no_reply_weight}]
  end

  defp choose([{outcome, _weight}], _random), do: {:ok, outcome}

  defp choose(weighted, random) do
    sample(weighted, MapSet.new(weighted, &elem(&1, 0)), random)
  end

  defp sample(weighted, outcomes, random) when is_atom(random) do
    if Code.ensure_loaded(random) == {:module, random} and
         function_exported?(random, :weighted_choice, 1) do
      case random.weighted_choice(weighted) do
        {:ok, outcome} ->
          if MapSet.member?(outcomes, outcome),
            do: {:ok, outcome},
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

  defp sample(_weighted, _outcomes, _random), do: {:error, :invalid_random_source}

  defp valid_weight?(weight) when is_integer(weight),
    do: weight >= 0 and weight <= @max_float

  defp valid_weight?(weight) when is_float(weight),
    do: weight == weight and weight >= 0 and weight <= @max_float

  defp valid_weight?(_weight), do: false
end

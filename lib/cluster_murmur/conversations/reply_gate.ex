defmodule ClusterMurmur.Conversations.ReplyGate do
  @moduledoc """
  Evaluates one bounded event-group reply probability with injected randomness.

  Endpoint probabilities are deterministic. Intermediate probabilities consume
  exactly one uniform sample and return an explicit reply or no-reply outcome.
  """

  alias ClusterMurmur.Conversations.ReplyGateDecision
  alias ClusterMurmur.DomainLimits

  @group_keys [:id, :reply_probability]
  @group_key_count length(@group_keys)
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()

  @type error :: :invalid_event_group | :invalid_random_source | :invalid_random_value

  @doc "Returns an explicit reply gate outcome for one exact event group."
  @spec evaluate(term(), module()) :: {:ok, ReplyGateDecision.t()} | {:error, error()}
  def evaluate(group, random) do
    with {:ok, probability} <- validate_group(group) do
      evaluate_probability(probability, random)
    end
  rescue
    _error -> {:error, :invalid_event_group}
  catch
    _kind, _reason -> {:error, :invalid_event_group}
  end

  defp validate_group(%{id: id, reply_probability: probability} = group) do
    if not is_struct(group) and map_size(group) == @group_key_count and
         Enum.all?(@group_keys, &Map.has_key?(group, &1)) and valid_id?(id) and
         valid_probability?(probability),
       do: {:ok, probability},
       else: {:error, :invalid_event_group}
  end

  defp validate_group(_group), do: {:error, :invalid_event_group}

  defp evaluate_probability(probability, _random) when probability == 0,
    do: decision(:no_reply)

  defp evaluate_probability(probability, _random) when probability == 1,
    do: decision(:reply)

  defp evaluate_probability(probability, random) do
    with {:ok, uniform} <- sample_uniform(random) do
      if uniform < probability,
        do: decision(:reply),
        else: decision(:no_reply)
    end
  end

  defp sample_uniform(random) when is_atom(random) do
    if Code.ensure_loaded(random) == {:module, random} and function_exported?(random, :uniform, 0) do
      case random.uniform() do
        value when is_float(value) and value >= 0.0 and value < 1.0 -> {:ok, value}
        _value -> {:error, :invalid_random_value}
      end
    else
      {:error, :invalid_random_source}
    end
  rescue
    _error -> {:error, :invalid_random_source}
  catch
    _kind, _reason -> {:error, :invalid_random_source}
  end

  defp sample_uniform(_random), do: {:error, :invalid_random_source}

  defp decision(outcome), do: {:ok, %ReplyGateDecision{outcome: outcome}}

  defp valid_id?(value) when is_binary(value) and byte_size(value) in 1..@max_id_bytes,
    do: String.valid?(value) and Regex.match?(@id_pattern, value)

  defp valid_id?(_value), do: false

  defp valid_probability?(value) when is_integer(value), do: value in 0..1

  defp valid_probability?(value) when is_float(value),
    do: value == value and value >= 0.0 and value <= 1.0

  defp valid_probability?(_value), do: false
end

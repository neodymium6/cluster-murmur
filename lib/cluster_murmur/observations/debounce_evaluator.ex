defmodule ClusterMurmur.Observations.DebounceEvaluator do
  @moduledoc """
  Purely advances bounded observation state through configured debounce.

  The evaluator consumes validated snapshots and prior durable state. It does
  not persist state, classify an event, read a clock, or perform observation.
  """

  alias ClusterMurmur.DomainLimits

  alias ClusterMurmur.Observations.{
    DebouncePolicy,
    EntityState,
    EntityStateValidator,
    Observation,
    Validator
  }

  @policy_keys DebouncePolicy.__struct__() |> Map.keys()
  @policy_key_count length(@policy_keys)
  @max_threshold DomainLimits.max_safe_integer()

  @type error ::
          :invalid_debounce_policy
          | :invalid_entity_state
          | :invalid_observation
          | :observation_identity_mismatch
          | :stale_observation

  @doc "Projects one observation into the next validated durable entity state."
  @spec evaluate(term(), term(), term()) :: {:ok, EntityState.t()} | {:error, error()}
  def evaluate(previous, observation, policy) do
    with :ok <- validate_previous(previous),
         :ok <- validate_observation(observation),
         :ok <- validate_policy(policy),
         :ok <- validate_correlation(previous, observation),
         {:ok, next} <- advance(previous, observation, policy),
         :ok <- EntityStateValidator.validate(next) do
      {:ok, next}
    else
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :invalid_entity_state}
  catch
    _kind, _reason -> {:error, :invalid_entity_state}
  end

  defp validate_previous(nil), do: :ok
  defp validate_previous(previous), do: EntityStateValidator.validate(previous)

  defp validate_observation(observation) do
    case Validator.validate(observation) do
      :ok -> :ok
      {:error, :invalid_observation} -> {:error, :invalid_observation}
    end
  end

  defp validate_policy(%DebouncePolicy{} = policy) do
    if map_size(policy) == @policy_key_count and
         Enum.all?(@policy_keys, &Map.has_key?(policy, &1)) and
         valid_threshold?(policy.healthy_threshold) and
         valid_threshold?(policy.unhealthy_threshold),
       do: :ok,
       else: {:error, :invalid_debounce_policy}
  end

  defp validate_policy(_policy), do: {:error, :invalid_debounce_policy}

  defp valid_threshold?(value), do: is_integer(value) and value in 1..@max_threshold

  defp validate_correlation(nil, %Observation{}), do: :ok

  defp validate_correlation(%EntityState{} = previous, %Observation{} = observation) do
    cond do
      previous.source != observation.source or previous.subject != observation.subject ->
        {:error, :observation_identity_mismatch}

      DateTime.compare(observation.observed_at, previous.last_observed_at) != :gt ->
        {:error, :stale_observation}

      true ->
        :ok
    end
  end

  defp advance(nil, observation, policy) do
    pending(observation, :unknown, nil, observation.state, 1, policy)
  end

  defp advance(previous, observation, _policy) when previous.current_state == observation.state do
    {:ok, state(observation, previous.current_state, nil, 0, previous.last_changed_at)}
  end

  defp advance(previous, observation, policy) do
    count =
      if previous.pending_state == observation.state,
        do: previous.consecutive_count + 1,
        else: 1

    pending(
      observation,
      previous.current_state,
      previous.last_changed_at,
      observation.state,
      count,
      policy
    )
  end

  defp pending(observation, current, changed_at, pending_state, count, policy) do
    if count >= threshold(policy, pending_state) do
      {:ok, state(observation, pending_state, nil, 0, observation.observed_at)}
    else
      {:ok, state(observation, current, pending_state, count, changed_at)}
    end
  end

  defp threshold(policy, :healthy), do: policy.healthy_threshold
  defp threshold(policy, :unhealthy), do: policy.unhealthy_threshold

  defp state(observation, current, pending, count, changed_at) do
    %EntityState{
      source: observation.source,
      subject: observation.subject,
      current_state: current,
      pending_state: pending,
      consecutive_count: count,
      last_observed_at: observation.observed_at,
      last_changed_at: changed_at,
      facts: observation.facts,
      labels: observation.labels
    }
  end
end

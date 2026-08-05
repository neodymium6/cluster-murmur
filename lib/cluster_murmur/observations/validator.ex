defmodule ClusterMurmur.Observations.Validator do
  @moduledoc """
  Validates one exact normalized observation without exposing supplied values.

  Observation payloads share the bounded entity-state boundary that later
  persistence and debounce evaluation consume.
  """

  alias ClusterMurmur.Observations.{EntityState, EntityStateValidator, Observation}

  @observation_keys Observation.__struct__() |> Map.keys()
  @observation_key_count length(@observation_keys)
  @states [:healthy, :unhealthy]

  @type error :: :invalid_observation

  @doc "Validates one complete normalized observation."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%Observation{} = observation) do
    with true <- exact?(observation),
         true <- observation.state in @states,
         :ok <- validate_as_initial_progress(observation) do
      :ok
    else
      _failure -> {:error, :invalid_observation}
    end
  rescue
    _error -> {:error, :invalid_observation}
  catch
    _kind, _reason -> {:error, :invalid_observation}
  end

  def validate(_observation), do: {:error, :invalid_observation}

  defp exact?(observation) do
    map_size(observation) == @observation_key_count and
      Enum.all?(@observation_keys, &Map.has_key?(observation, &1))
  end

  defp validate_as_initial_progress(observation) do
    EntityStateValidator.validate(%EntityState{
      source: observation.source,
      subject: observation.subject,
      current_state: :unknown,
      pending_state: observation.state,
      consecutive_count: 1,
      last_observed_at: observation.observed_at,
      last_changed_at: nil,
      facts: observation.facts,
      labels: observation.labels
    })
  end
end

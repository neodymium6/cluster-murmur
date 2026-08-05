defmodule ClusterMurmur.Observations.EntityStateValidator do
  @moduledoc """
  Validates one exact bounded observation entity-state projection.

  The recursive facts and labels reuse the event validator's JSON-compatible
  budget. No debounce threshold or event decision is derived here.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Events.{Event, Validator}
  alias ClusterMurmur.Observations.EntityState

  @state_keys EntityState.__struct__() |> Map.keys()
  @state_key_count length(@state_keys)
  @committed_states [:unknown, :healthy, :unhealthy]
  @observed_states [:healthy, :unhealthy]
  @max_count DomainLimits.max_safe_integer()
  @max_encoded_payload_bytes 128 * 1_024
  @projected_event_id String.duplicate("e", 76)
  @projected_event_dedupe_key String.duplicate("d", 86)

  @type error :: :invalid_entity_state

  @doc "Validates one complete entity state without exposing supplied values."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%EntityState{} = state) do
    with true <- exact?(state),
         true <- state.current_state in @committed_states,
         true <- valid_pending?(state),
         true <- valid_times?(state),
         true <- valid_payload?(state),
         {:ok, _facts, _labels} <- encode_payloads(state.facts, state.labels) do
      :ok
    else
      _failure -> {:error, :invalid_entity_state}
    end
  rescue
    _error -> {:error, :invalid_entity_state}
  catch
    _kind, _reason -> {:error, :invalid_entity_state}
  end

  def validate(_state), do: {:error, :invalid_entity_state}

  @doc false
  @spec encode_payloads(term(), term()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_entity_state}
  def encode_payloads(facts, labels) do
    with {:ok, facts} <- encode_json(facts),
         {:ok, labels} <- encode_json(labels),
         true <- byte_size(facts) + byte_size(labels) <= @max_encoded_payload_bytes do
      {:ok, facts, labels}
    else
      _failure -> {:error, :invalid_entity_state}
    end
  rescue
    _error -> {:error, :invalid_entity_state}
  catch
    _kind, _reason -> {:error, :invalid_entity_state}
  end

  defp exact?(state) do
    map_size(state) == @state_key_count and
      Enum.all?(@state_keys, &Map.has_key?(state, &1))
  end

  defp valid_pending?(%EntityState{
         current_state: :unknown,
         pending_state: pending,
         consecutive_count: count
       }),
       do: pending in @observed_states and is_integer(count) and count in 1..@max_count

  defp valid_pending?(%EntityState{pending_state: nil, consecutive_count: 0}), do: true

  defp valid_pending?(%EntityState{
         current_state: current,
         pending_state: pending,
         consecutive_count: count
       }),
       do:
         current in @observed_states and pending in @observed_states and pending != current and
           is_integer(count) and count in 1..@max_count

  defp valid_pending?(_state), do: false

  defp valid_times?(%EntityState{
         current_state: :unknown,
         last_observed_at: %DateTime{},
         last_changed_at: nil
       }),
       do: true

  defp valid_times?(%EntityState{
         current_state: current,
         last_observed_at: %DateTime{} = observed_at,
         last_changed_at: %DateTime{} = changed_at
       })
       when current in @observed_states,
       do: DateTime.compare(changed_at, observed_at) in [:lt, :eq]

  defp valid_times?(_state), do: false

  defp valid_payload?(state) do
    Validator.validate(%Event{
      id: @projected_event_id,
      type: "observation.entity-state",
      source: state.source,
      subject: state.subject,
      group: nil,
      severity: "warning",
      previous: "unhealthy",
      current: "unhealthy",
      occurred_at: state.last_observed_at,
      observed_at: state.last_changed_at,
      dedupe_key: @projected_event_dedupe_key,
      correlation_key: nil,
      facts: state.facts,
      labels: state.labels
    }) == :ok
  end

  defp encode_json(value) do
    {:ok, value |> normalize_nulls() |> :json.encode() |> IO.iodata_to_binary()}
  end

  defp normalize_nulls(nil), do: :null

  defp normalize_nulls(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, normalize_nulls(nested)} end)

  defp normalize_nulls(value) when is_list(value), do: Enum.map(value, &normalize_nulls/1)
  defp normalize_nulls(value), do: value
end

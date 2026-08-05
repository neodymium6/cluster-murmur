defmodule ClusterMurmur.Observations.EventProjector do
  @moduledoc """
  Purely projects a committed observation-state change into one bounded event.

  IDs and dedupe keys are deterministic hashes of application-confirmed
  identity and time facts. No persistence, dedupe-window policy, or publication
  occurs here.
  """

  alias ClusterMurmur.Events.{Event, StateTransition, Validator}
  alias ClusterMurmur.Observations.{EntityState, EntityStateValidator}

  @type error :: :invalid_observation_transition
  @type result :: {:ok, Event.t()} | :no_event | {:error, error()}

  @doc "Returns a bounded event only when the committed state requires one."
  @spec project(term(), term()) :: result()
  def project(previous, next) do
    with :ok <- validate_previous(previous),
         :ok <- validate_next(next),
         :ok <- validate_correlation(previous, next) do
      previous_state = if previous == nil, do: :unknown, else: previous.current_state

      case committed_transition(previous_state, next.current_state) do
        {:ok, type} -> build_event(type, previous_state, next)
        :no_event -> :no_event
      end
    else
      _failure -> {:error, :invalid_observation_transition}
    end
  rescue
    _error -> {:error, :invalid_observation_transition}
  catch
    _kind, _reason -> {:error, :invalid_observation_transition}
  end

  defp validate_previous(nil), do: :ok
  defp validate_previous(state), do: EntityStateValidator.validate(state)
  defp validate_next(state), do: EntityStateValidator.validate(state)

  defp validate_correlation(nil, %EntityState{current_state: :unknown}), do: :ok

  defp validate_correlation(nil, %EntityState{} = next) do
    if committed_progress_cleared?(next) and
         same_datetime?(next.last_changed_at, next.last_observed_at),
       do: :ok,
       else: {:error, :invalid_observation_transition}
  end

  defp validate_correlation(%EntityState{} = previous, %EntityState{} = next) do
    if previous.source == next.source and previous.subject == next.subject and
         DateTime.compare(next.last_observed_at, previous.last_observed_at) == :gt and
         valid_changed_time_progression?(previous, next),
       do: :ok,
       else: {:error, :invalid_observation_transition}
  end

  defp valid_changed_time_progression?(previous, next)
       when previous.current_state == next.current_state,
       do: same_optional_datetime?(previous.last_changed_at, next.last_changed_at)

  defp valid_changed_time_progression?(_previous, next),
    do:
      committed_progress_cleared?(next) and
        same_datetime?(next.last_changed_at, next.last_observed_at)

  defp committed_progress_cleared?(next),
    do: next.pending_state == nil and next.consecutive_count == 0

  defp same_optional_datetime?(nil, nil), do: true

  defp same_optional_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: same_datetime?(left, right)

  defp same_optional_datetime?(_left, _right), do: false

  defp same_datetime?(left, right), do: DateTime.compare(left, right) == :eq

  defp committed_transition(_previous, :unknown), do: :no_event
  defp committed_transition(previous, current), do: StateTransition.classify(previous, current)

  defp build_event(type, previous, next) do
    event = %Event{
      id: deterministic_id(type, next),
      type: type,
      source: next.source,
      subject: next.subject,
      group: nil,
      severity: severity(type),
      previous: Atom.to_string(previous),
      current: Atom.to_string(next.current_state),
      occurred_at: next.last_changed_at,
      observed_at: next.last_observed_at,
      dedupe_key: deterministic_dedupe_key(type, next),
      correlation_key: nil,
      facts: next.facts,
      labels: next.labels
    }

    if Validator.validate(event) == :ok,
      do: {:ok, event},
      else: {:error, :invalid_observation_transition}
  end

  defp deterministic_id(type, next) do
    "observation-" <>
      digest([
        type,
        next.source,
        next.subject,
        Integer.to_string(DateTime.to_unix(next.last_observed_at, :microsecond))
      ])
  end

  defp deterministic_dedupe_key(type, next),
    do: type <> ":" <> digest([next.source, next.subject])

  defp digest(parts) do
    :crypto.hash(:sha256, Enum.intersperse(parts, <<0>>))
    |> Base.encode16(case: :lower)
  end

  defp severity("observation.failed"), do: "warning"
  defp severity("observation.recovered"), do: "info"
end

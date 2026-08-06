defmodule ClusterMurmur.Discord.PublicationAttemptRecovery do
  @moduledoc """
  Purely classifies loaded publication attempts during restart recovery.

  An abandoned open attempt may have reached Discord, so recovery never
  proposes retrying it. Terminal attempts require no action.
  """

  alias ClusterMurmur.Persistence.{
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator
  }

  alias ClusterMurmur.DateTimeValidator

  @type action :: :mark_ambiguous | :no_action
  @type error :: :invalid_datetime | :invalid_publication_attempt_record

  @doc "Returns the recovery action relative to one injected startup cutoff."
  @spec classify(term(), term()) :: {:ok, action()} | {:error, error()}
  def classify(%PublicationAttemptRecord{} = attempt, cutoff) do
    with :ok <- PublicationAttemptRecordValidator.validate(attempt),
         :ok <- DateTimeValidator.validate_storage_utc(cutoff) do
      case attempt.status do
        status when status in [:started, :dispatching] ->
          classify_open(attempt.started_at, cutoff)

        status when status in [:succeeded, :failed, :ambiguous] ->
          {:ok, :no_action}
      end
    else
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      {:error, :invalid_publication_attempt_record} = error -> error
    end
  end

  def classify(_attempt, _cutoff), do: {:error, :invalid_publication_attempt_record}

  defp classify_open(started_at, cutoff) do
    if DateTime.compare(started_at, cutoff) in [:lt, :eq],
      do: {:ok, :mark_ambiguous},
      else: {:ok, :no_action}
  end
end

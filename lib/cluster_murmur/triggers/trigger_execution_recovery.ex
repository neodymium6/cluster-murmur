defmodule ClusterMurmur.Triggers.TriggerExecutionRecovery do
  @moduledoc """
  Purely classifies one loaded trigger execution for later recovery policy.

  The supplied cutoff is an application-owned fact. This module reads neither
  clocks nor storage and never mutates or retries an execution.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.{TriggerExecution, TriggerExecutionValidator}

  @type decision :: :abandoned | :recent | :terminal
  @type error :: :invalid_datetime | :invalid_execution

  @doc "Classifies one exact loaded execution relative to a supplied UTC abandonment cutoff."
  @spec classify(term(), term()) :: {:ok, decision()} | {:error, error()}
  def classify(%TriggerExecution{} = execution, cutoff) do
    with :ok <- TriggerExecutionValidator.validate(execution),
         :ok <- DateTimeValidator.validate_storage_utc(cutoff) do
      {:ok, decide(execution, cutoff)}
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  def classify(_execution, _cutoff), do: {:error, :invalid_execution}

  defp decide(%TriggerExecution{status: status}, _cutoff)
       when status in [:completed, :failed],
       do: :terminal

  defp decide(%TriggerExecution{status: :started, executed_at: executed_at}, cutoff) do
    if DateTime.compare(executed_at, cutoff) in [:lt, :eq], do: :abandoned, else: :recent
  end
end

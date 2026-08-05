defmodule ClusterMurmur.Persistence.TriggerExecutionValidator do
  @moduledoc """
  Validates exact loaded trigger-execution projections without exposing values.

  Persistence inputs may accept UTC precision that Ecto later normalizes, while
  loaded capabilities must retain the exact precision and metadata returned by
  the fixed schema.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Events.Validator, as: EventValidator
  alias ClusterMurmur.Persistence.TriggerExecution

  @execution_keys TriggerExecution.__struct__() |> Map.keys()
  @execution_key_count length(@execution_keys)
  @loaded_metadata Ecto.put_meta(%TriggerExecution{}, state: :loaded).__meta__
  @trigger_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @error_class_pattern ~r/\A[a-z][a-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_error_class_bytes 128

  @type error :: :invalid_execution

  @doc "Validates one exact loaded execution and its closed lifecycle state."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%TriggerExecution{} = execution) do
    if exact_loaded?(execution) and valid_fields?(execution) and valid_lifecycle?(execution),
      do: :ok,
      else: {:error, :invalid_execution}
  rescue
    _error -> {:error, :invalid_execution}
  catch
    _kind, _reason -> {:error, :invalid_execution}
  end

  def validate(_execution), do: {:error, :invalid_execution}

  @doc "Validates one exact loaded execution that remains in started state."
  @spec validate_started(term()) :: :ok | {:error, error()}
  def validate_started(%TriggerExecution{status: :started} = execution), do: validate(execution)
  def validate_started(_execution), do: {:error, :invalid_execution}

  defp exact_loaded?(execution) do
    map_size(execution) == @execution_key_count and
      Enum.all?(@execution_keys, &Map.has_key?(execution, &1)) and
      execution.__meta__ == @loaded_metadata
  end

  defp valid_fields?(execution) do
    valid_trigger_id?(execution.trigger_id) and
      EventValidator.validate_id(execution.event_id) == :ok and
      valid_loaded_datetime?(execution.executed_at) and
      valid_loaded_datetime?(execution.cooldown_until) and
      DateTime.compare(execution.cooldown_until, execution.executed_at) in [:gt, :eq]
  end

  defp valid_lifecycle?(%TriggerExecution{status: status, error_class: nil})
       when status in [:started, :completed],
       do: true

  defp valid_lifecycle?(%TriggerExecution{status: :failed, error_class: error_class}),
    do: valid_error_class?(error_class)

  defp valid_lifecycle?(_execution), do: false

  defp valid_trigger_id?(trigger_id)
       when is_binary(trigger_id) and byte_size(trigger_id) <= @max_id_bytes do
    String.valid?(trigger_id) and Regex.match?(@trigger_id_pattern, trigger_id)
  end

  defp valid_trigger_id?(_trigger_id), do: false

  defp valid_loaded_datetime?(%DateTime{microsecond: {_value, 6}} = datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp valid_loaded_datetime?(_datetime), do: false

  defp valid_error_class?(error_class)
       when is_binary(error_class) and byte_size(error_class) in 1..@max_error_class_bytes do
    String.valid?(error_class) and not String.contains?(error_class, <<0>>) and
      Regex.match?(@error_class_pattern, error_class)
  end

  defp valid_error_class?(_error_class), do: false
end

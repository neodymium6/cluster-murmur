defmodule ClusterMurmur.Persistence.PublicationAttemptRecordValidator do
  @moduledoc """
  Validates exact loaded Discord publication-attempt records.

  Lifecycle validation preserves the distinction between classified failures
  and ambiguous interruption without exposing durable values.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.PublicationAttemptRecord

  @record_keys PublicationAttemptRecord.__struct__() |> Map.keys()
  @record_key_count length(@record_keys)
  @loaded_metadata Ecto.put_meta(%PublicationAttemptRecord{}, state: :loaded).__meta__
  @max_sqlite_integer 9_223_372_036_854_775_807
  @external_errors [
    :authentication_failed,
    :invalid_request,
    :invalid_response,
    :rate_limited,
    :timeout,
    :unavailable
  ]

  @type error :: :invalid_publication_attempt_record

  @doc "Validates one exact loaded attempt through its complete lifecycle boundary."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%PublicationAttemptRecord{} = record) do
    if exact_loaded?(record) and valid_message_id?(record.message_id) and
         loaded_datetime?(record.started_at) and valid_lifecycle?(record),
       do: :ok,
       else: {:error, :invalid_publication_attempt_record}
  rescue
    _error -> {:error, :invalid_publication_attempt_record}
  catch
    _kind, _reason -> {:error, :invalid_publication_attempt_record}
  end

  def validate(_record), do: {:error, :invalid_publication_attempt_record}

  defp exact_loaded?(record) do
    map_size(record) == @record_key_count and Enum.all?(@record_keys, &Map.has_key?(record, &1)) and
      record.__meta__ == @loaded_metadata
  end

  defp valid_message_id?(id), do: is_integer(id) and id in 1..@max_sqlite_integer

  defp valid_lifecycle?(%PublicationAttemptRecord{
         status: :started,
         completed_at: nil,
         error_class: nil
       }),
       do: true

  defp valid_lifecycle?(
         %PublicationAttemptRecord{
           status: :succeeded,
           completed_at: completed_at,
           error_class: nil
         } = record
       ),
       do: valid_completion?(record.started_at, completed_at)

  defp valid_lifecycle?(
         %PublicationAttemptRecord{
           status: :failed,
           completed_at: completed_at,
           error_class: error_class
         } = record
       )
       when error_class in @external_errors,
       do: valid_completion?(record.started_at, completed_at)

  defp valid_lifecycle?(
         %PublicationAttemptRecord{
           status: :ambiguous,
           completed_at: completed_at,
           error_class: :interrupted
         } = record
       ),
       do: valid_completion?(record.started_at, completed_at)

  defp valid_lifecycle?(_record), do: false

  defp valid_completion?(started_at, completed_at),
    do:
      loaded_datetime?(completed_at) and DateTime.compare(completed_at, started_at) in [:gt, :eq]

  defp loaded_datetime?(%DateTime{microsecond: {_value, 6}} = datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp loaded_datetime?(_datetime), do: false
end

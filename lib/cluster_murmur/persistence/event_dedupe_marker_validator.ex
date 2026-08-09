defmodule ClusterMurmur.Persistence.EventDedupeMarkerValidator do
  @moduledoc """
  Validates exact loaded event dedupe markers without exposing their values.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.Validator
  alias ClusterMurmur.Persistence.EventDedupeMarker

  @record_keys EventDedupeMarker.__struct__() |> Map.keys()
  @record_key_count length(@record_keys)
  @loaded_metadata Ecto.put_meta(%EventDedupeMarker{}, state: :loaded).__meta__

  @type error :: :invalid_event_dedupe_marker

  @doc "Validates one exact loaded marker through the persistence boundary."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%EventDedupeMarker{} = marker) do
    if exact_loaded?(marker) and Validator.validate_id(marker.dedupe_key) == :ok and
         Validator.validate_id(marker.event_id) == :ok and loaded_datetime?(marker.accepted_at),
       do: :ok,
       else: {:error, :invalid_event_dedupe_marker}
  rescue
    _error -> {:error, :invalid_event_dedupe_marker}
  catch
    _kind, _reason -> {:error, :invalid_event_dedupe_marker}
  end

  def validate(_marker), do: {:error, :invalid_event_dedupe_marker}

  defp exact_loaded?(marker) do
    map_size(marker) == @record_key_count and
      Enum.all?(@record_keys, &Map.has_key?(marker, &1)) and marker.__meta__ == @loaded_metadata
  end

  defp loaded_datetime?(%DateTime{microsecond: {_value, 6}} = datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp loaded_datetime?(_datetime), do: false
end

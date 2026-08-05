defmodule ClusterMurmur.Persistence.PersonaCooldownRecordValidator do
  @moduledoc """
  Validates exact loaded persona cooldown records without exposing their values.
  """

  alias ClusterMurmur.{DateTimeValidator, DomainLimits}
  alias ClusterMurmur.Persistence.PersonaCooldownRecord

  @record_keys PersonaCooldownRecord.__struct__() |> Map.keys()
  @record_key_count length(@record_keys)
  @loaded_metadata Ecto.put_meta(%PersonaCooldownRecord{}, state: :loaded).__meta__
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_cooldown_microseconds DomainLimits.max_interval_ms() * 1_000

  @type error :: :invalid_persona_cooldown_record

  @doc "Validates one exact loaded persona cooldown through the complete runtime boundary."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%PersonaCooldownRecord{} = record) do
    if exact_loaded?(record) and valid_persona_id?(record.persona_id) and
         loaded_datetime?(record.last_spoken_at) and loaded_datetime?(record.cooldown_until) and
         DateTime.diff(record.cooldown_until, record.last_spoken_at, :microsecond) in 0..@max_cooldown_microseconds,
       do: :ok,
       else: {:error, :invalid_persona_cooldown_record}
  rescue
    _error -> {:error, :invalid_persona_cooldown_record}
  catch
    _kind, _reason -> {:error, :invalid_persona_cooldown_record}
  end

  def validate(_record), do: {:error, :invalid_persona_cooldown_record}

  defp exact_loaded?(record) do
    map_size(record) == @record_key_count and Enum.all?(@record_keys, &Map.has_key?(record, &1)) and
      record.__meta__ == @loaded_metadata
  end

  defp valid_persona_id?(persona_id)
       when is_binary(persona_id) and byte_size(persona_id) in 1..@max_id_bytes do
    String.valid?(persona_id) and Regex.match?(@id_pattern, persona_id)
  end

  defp valid_persona_id?(_persona_id), do: false

  defp loaded_datetime?(%DateTime{microsecond: {_value, 6}} = datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp loaded_datetime?(_datetime), do: false
end

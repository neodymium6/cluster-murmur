defmodule ClusterMurmur.Generation.PersonaProjectionValidator do
  @moduledoc """
  Validates the exact bounded persona projection accepted by generation.
  """

  alias ClusterMurmur.Generation.PersonaProjection

  @projection_keys PersonaProjection.__struct__() |> Map.keys()
  @projection_key_count length(@projection_keys)
  @single_line_control_pattern ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\x{2028}\x{2029}]/u
  @max_display_name_bytes 128
  @max_instructions_bytes 64 * 1_024

  @type error :: :invalid_persona_projection

  @doc "Validates one exact persona identity and instruction projection."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%PersonaProjection{} = projection) do
    if exact?(projection) and valid_display_name?(projection.display_name) and
         valid_instructions?(projection.instructions),
       do: :ok,
       else: {:error, :invalid_persona_projection}
  rescue
    _error -> {:error, :invalid_persona_projection}
  catch
    _kind, _reason -> {:error, :invalid_persona_projection}
  end

  def validate(_projection), do: {:error, :invalid_persona_projection}

  defp exact?(projection) do
    map_size(projection) == @projection_key_count and
      Enum.all?(@projection_keys, &Map.has_key?(projection, &1))
  end

  defp valid_display_name?(value)
       when is_binary(value) and byte_size(value) in 1..@max_display_name_bytes do
    String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(@single_line_control_pattern, value)
  end

  defp valid_display_name?(_value), do: false

  defp valid_instructions?(value)
       when is_binary(value) and byte_size(value) in 1..@max_instructions_bytes,
       do: String.valid?(value)

  defp valid_instructions?(_value), do: false
end

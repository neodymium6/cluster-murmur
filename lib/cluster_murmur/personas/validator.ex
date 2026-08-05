defmodule ClusterMurmur.Personas.Validator do
  @moduledoc """
  Validates one exact bounded runtime persona without exposing its values.

  Configuration parsing uses the same boundary so later selection and
  generation code can safely revalidate persona values after process messages
  or other in-memory boundaries.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.Persona

  @persona_keys Persona.__struct__() |> Map.keys()
  @persona_key_count length(@persona_keys)
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @behavior_keys ["cooldown_ms", "reply_weight", "spontaneous_weight"]
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_interval_ms DomainLimits.max_interval_ms()
  @max_float DomainLimits.max_float()
  @max_display_name_bytes 128
  @max_avatar_bytes 2_048
  @max_prompt_bytes 64 * 1_024
  @max_interests 256

  @type error :: :invalid_persona

  @doc "Validates one complete version 1 persona runtime value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%Persona{} = persona) do
    if exact_persona?(persona) and valid_id?(persona.id) and
         valid_display_name?(persona.display_name) and valid_avatar?(persona.avatar) and
         valid_prompt?(persona.prompt) and is_boolean(persona.enabled) and
         valid_interests?(persona.interests) and valid_behavior?(persona.behavior) and
         persona.relationships == %{} and persona.metadata == %{},
       do: :ok,
       else: {:error, :invalid_persona}
  rescue
    _error -> {:error, :invalid_persona}
  catch
    _kind, _reason -> {:error, :invalid_persona}
  end

  def validate(_persona), do: {:error, :invalid_persona}

  defp exact_persona?(persona) do
    map_size(persona) == @persona_key_count and
      Enum.all?(@persona_keys, &Map.has_key?(persona, &1))
  end

  defp valid_id?(value) when is_binary(value) and byte_size(value) in 1..@max_id_bytes,
    do: String.valid?(value) and Regex.match?(@id_pattern, value)

  defp valid_id?(_value), do: false

  defp valid_display_name?(value)
       when is_binary(value) and byte_size(value) in 1..@max_display_name_bytes,
       do: String.valid?(value) and String.trim(value) != ""

  defp valid_display_name?(_value), do: false

  defp valid_avatar?(nil), do: true

  defp valid_avatar?(value) when is_binary(value) and byte_size(value) <= @max_avatar_bytes do
    with true <- String.valid?(value),
         false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value),
         normalized when is_binary(normalized) <- :uri_string.normalize(value),
         {:ok, %URI{scheme: "https", host: host, userinfo: nil}} <- URI.new(normalized) do
      is_binary(host) and host != ""
    else
      _failure -> false
    end
  end

  defp valid_avatar?(_value), do: false

  defp valid_prompt?(value)
       when is_binary(value) and byte_size(value) in 1..@max_prompt_bytes,
       do: String.valid?(value)

  defp valid_prompt?(_value), do: false

  defp valid_interests?(interests)
       when is_map(interests) and not is_struct(interests) and
              map_size(interests) <= @max_interests do
    Enum.all?(interests, fn {group_id, weight} ->
      valid_id?(group_id) and valid_weight?(weight)
    end)
  end

  defp valid_interests?(_interests), do: false

  defp valid_behavior?(behavior) when is_map(behavior) and not is_struct(behavior) do
    map_size(behavior) <= length(@behavior_keys) and
      Enum.all?(behavior, &valid_behavior_entry?/1)
  end

  defp valid_behavior?(_behavior), do: false

  defp valid_behavior_entry?({key, value})
       when key in ["reply_weight", "spontaneous_weight"],
       do: valid_weight?(value)

  defp valid_behavior_entry?({"cooldown_ms", value}),
    do: is_integer(value) and value in 0..@max_interval_ms

  defp valid_behavior_entry?(_entry), do: false

  defp valid_weight?(value) when is_integer(value),
    do: value >= 0 and value <= @max_float

  defp valid_weight?(value) when is_float(value),
    do: value == value and value >= 0 and value <= @max_float

  defp valid_weight?(_value), do: false
end

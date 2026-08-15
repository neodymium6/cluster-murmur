defmodule ClusterMurmur.Generation.ProviderOutputNormalizer do
  @moduledoc """
  Applies narrow mechanical normalization to one provider text response.

  Content policy remains owned by the shared message validator.
  """

  alias ClusterMurmur.Generation.{PersonaProjection, PersonaProjectionValidator}
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  @forbidden_control_pattern ~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}]/u
  @horizontal_whitespace_pattern ~r/[^\S\n]+/u
  @colon_delimiters [":", "："]
  @dash_delimiters ["-", "–", "—"]
  @max_raw_bytes 64 * 1_024
  @max_output_characters 16 * 1_024

  @rejection_reasons [
    :blank_output,
    :character_limit_exceeded,
    :invalid_provider_output,
    :invalid_unicode
  ]

  @type error ::
          :blank_output
          | :character_limit_exceeded
          | :invalid_provider_output
          | :invalid_unicode

  @doc "Returns normalized content under the injected character limit."
  @spec normalize(term(), term(), term()) :: {:ok, String.t()} | {:error, error()}
  def normalize(raw, %PersonaProjection{} = persona, character_limit)
      when is_binary(raw) and byte_size(raw) <= @max_raw_bytes and
             is_integer(character_limit) and character_limit in 1..@max_output_characters do
    with :ok <- validate_unicode(raw),
         :ok <- PersonaProjectionValidator.validate(persona),
         prepared <- normalize_spacing(raw),
         display_name <- normalize_spacing(persona.display_name),
         normalized <- strip_speaker_label(prepared, display_name) |> String.trim(),
         :ok <- validate_character_limit(normalized, character_limit),
         :ok <- validate_content(normalized) do
      {:ok, normalized}
    else
      {:error, reason} when reason in @rejection_reasons -> {:error, reason}
      _failure -> {:error, :invalid_provider_output}
    end
  rescue
    _error -> {:error, :invalid_provider_output}
  catch
    _kind, _reason -> {:error, :invalid_provider_output}
  end

  def normalize(_raw, _persona, _character_limit),
    do: {:error, :invalid_provider_output}

  defp validate_unicode(raw) do
    if String.valid?(raw), do: :ok, else: {:error, :invalid_unicode}
  end

  defp validate_character_limit(content, character_limit) do
    if String.length(content) <= character_limit,
      do: :ok,
      else: {:error, :character_limit_exceeded}
  end

  defp validate_content(content) do
    case MessageValidator.classify_content(content) do
      :ok -> :ok
      {:error, :blank_content} -> {:error, :blank_output}
      {:error, :invalid_content} -> {:error, :invalid_provider_output}
    end
  end

  defp normalize_spacing(raw) do
    raw
    |> then(&Regex.replace(@forbidden_control_pattern, &1, " "))
    |> then(&Regex.replace(@horizontal_whitespace_pattern, &1, " "))
    |> String.trim()
  end

  defp strip_speaker_label(content, display_name) do
    strip_colon_label(content, display_name) ||
      strip_dash_label(content, display_name) || content
  end

  defp strip_colon_label(content, display_name) do
    Enum.find_value(@colon_delimiters, false, fn delimiter ->
      strip_label_with_boundary(content, display_name <> delimiter)
    end)
  end

  defp strip_dash_label(content, display_name) do
    Enum.find_value(@dash_delimiters, false, fn delimiter ->
      strip_label_with_boundary(content, display_name <> " " <> delimiter)
    end)
  end

  defp strip_label_with_boundary(content, prefix) do
    with true <- String.starts_with?(content, prefix),
         remainder <- String.replace_prefix(content, prefix, ""),
         true <- remainder == "" or Regex.match?(~r/\A\s/u, remainder) do
      remainder
    else
      _failure -> false
    end
  end
end

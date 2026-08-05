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

  @type error :: :invalid_provider_output

  @doc "Returns normalized content under the injected character limit."
  @spec normalize(term(), term(), term()) :: {:ok, String.t()} | {:error, error()}
  def normalize(raw, %PersonaProjection{} = persona, character_limit)
      when is_binary(raw) and byte_size(raw) <= @max_raw_bytes and
             is_integer(character_limit) and character_limit in 1..@max_output_characters do
    with true <- String.valid?(raw),
         :ok <- PersonaProjectionValidator.validate(persona),
         prepared <- normalize_spacing(raw),
         display_name <- normalize_spacing(persona.display_name),
         normalized <- strip_speaker_label(prepared, display_name) |> String.trim(),
         true <- String.length(normalized) <= character_limit,
         :ok <- MessageValidator.validate_content(normalized) do
      {:ok, normalized}
    else
      _failure -> {:error, :invalid_provider_output}
    end
  rescue
    _error -> {:error, :invalid_provider_output}
  catch
    _kind, _reason -> {:error, :invalid_provider_output}
  end

  def normalize(_raw, _persona, _character_limit),
    do: {:error, :invalid_provider_output}

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

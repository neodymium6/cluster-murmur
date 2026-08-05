defmodule ClusterMurmur.Messages.Validator do
  @moduledoc """
  Validates one bounded generated message without exposing supplied content.

  This hard runtime boundary rejects URL and Discord mention forms before
  persistence. A configured publication character limit may be stricter.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Messages.Message

  @message_keys Message.__struct__() |> Map.keys()
  @message_key_count length(@message_keys)
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @snowflake_pattern ~r/\A[1-9][0-9]{0,19}\z/
  @forbidden_control_pattern ~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}]/u
  @forbidden_scheme_pattern ~r/[A-Za-z][A-Za-z0-9+.-]*:[^\s]/u
  @forbidden_network_path_pattern ~r/\/\/[^\s\/]+(?:\/[^\s]*)?/u
  @unicode_dot_pattern ~r/[。．｡]/u
  @domain_token_separator_pattern ~r/[^\p{L}\p{N}\p{M}\p{Cf}.\-]+/u
  @domain_ignorable_pattern ~r/[\p{M}\p{Cf}]/u
  @domain_label_pattern ~r/\A[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\z/u
  @domain_suffix_pattern ~r/\A\p{L}[\p{L}\p{N}-]*\z/u
  @visible_content_pattern ~r/[^\p{Z}\p{C}\p{M}]/u
  @forbidden_ip_pattern ~r/(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])/u
  @forbidden_mention_pattern ~r/(?:@everyone|@here|<@!?[0-9]+>|<@&[0-9]+>)/u
  @origins [:llm, :fallback]
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_content_bytes 16 * 1_024
  @max_discord_id_bytes 32
  @max_snowflake 18_446_744_073_709_551_615

  @type error :: :invalid_message

  @doc "Validates one exact bounded message and its safe output content."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(
        %Message{
          conversation_id: conversation_id,
          persona_id: persona_id,
          origin: origin,
          content: content,
          discord_message_id: discord_message_id,
          inserted_at: inserted_at
        } = message
      )
      when origin in @origins do
    if exact_message?(message) and valid_portable_id?(conversation_id) and
         valid_portable_id?(persona_id) and valid_content?(content) and
         valid_discord_id?(discord_message_id) and valid_datetime?(inserted_at),
       do: :ok,
       else: {:error, :invalid_message}
  rescue
    _error -> {:error, :invalid_message}
  catch
    _kind, _reason -> {:error, :invalid_message}
  end

  def validate(_message), do: {:error, :invalid_message}

  @doc "Validates bounded output content without constructing a message."
  @spec validate_content(term()) :: :ok | {:error, error()}
  def validate_content(content) do
    if valid_content?(content), do: :ok, else: {:error, :invalid_message}
  rescue
    _error -> {:error, :invalid_message}
  catch
    _kind, _reason -> {:error, :invalid_message}
  end

  defp exact_message?(message) do
    map_size(message) == @message_key_count and
      Enum.all?(@message_keys, &Map.has_key?(message, &1))
  end

  defp valid_portable_id?(value)
       when is_binary(value) and byte_size(value) in 1..@max_id_bytes do
    String.valid?(value) and Regex.match?(@id_pattern, value)
  end

  defp valid_portable_id?(_value), do: false

  defp valid_content?(content)
       when is_binary(content) and byte_size(content) in 1..@max_content_bytes do
    String.valid?(content) and not blank?(content) and not unsafe_output?(content)
  end

  defp valid_content?(_content), do: false

  defp blank?(content) do
    content
    |> String.normalize(:nfkc)
    |> then(&(not Regex.match?(@visible_content_pattern, &1)))
  end

  defp unsafe_output?(content) do
    normalized = @unicode_dot_pattern |> Regex.replace(content, ".") |> String.normalize(:nfkc)

    Regex.match?(@forbidden_control_pattern, normalized) or
      Regex.match?(@forbidden_scheme_pattern, normalized) or
      Regex.match?(@forbidden_network_path_pattern, normalized) or
      domain_like?(normalized) or
      Regex.match?(@forbidden_ip_pattern, normalized) or
      Regex.match?(@forbidden_mention_pattern, normalized)
  end

  defp domain_like?(content) do
    content
    |> String.split(@domain_token_separator_pattern, trim: true)
    |> Enum.any?(&domain_token?/1)
  end

  defp domain_token?(token) do
    token
    |> String.trim("-")
    |> String.split(".", trim: false)
    |> Enum.reduce_while(false, fn label, previous_label? ->
      detection_label = Regex.replace(@domain_ignorable_pattern, label, "")
      valid_label? = Regex.match?(@domain_label_pattern, detection_label)

      if previous_label? and valid_label? and
           Regex.match?(@domain_suffix_pattern, detection_label),
         do: {:halt, :domain},
         else: {:cont, valid_label?}
    end)
    |> Kernel.==(:domain)
  end

  defp valid_discord_id?(nil), do: true

  defp valid_discord_id?(discord_id)
       when is_binary(discord_id) and byte_size(discord_id) in 1..@max_discord_id_bytes do
    String.valid?(discord_id) and Regex.match?(@snowflake_pattern, discord_id) and
      canonical_snowflake?(discord_id)
  end

  defp valid_discord_id?(_discord_id), do: false

  defp canonical_snowflake?(discord_id) do
    case Integer.parse(discord_id) do
      {value, ""} when value in 1..@max_snowflake -> Integer.to_string(value) == discord_id
      _invalid -> false
    end
  end

  defp valid_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok
end

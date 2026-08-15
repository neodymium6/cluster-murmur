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
  @japanese_sentence_endings [
    "です",
    "ます",
    "ません",
    "でした",
    "ました",
    "でしょう",
    "ください",
    "である",
    "だった",
    "だ",
    "ない",
    "した",
    "いる",
    "ある"
  ]
  @japanese_sentence_body_pattern ~r/\A[\p{Han}\p{Hiragana}\p{Katakana}\p{N}\p{M}ー々〆ヵヶ、！？「」『』（）・]+\z/u
  @japanese_reference_cues [
    "参照",
    "リンク",
    "ドメイン",
    "ホスト",
    "アドレス",
    "アクセス",
    "接続",
    "サイト"
  ]
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
  @type content_error :: :blank_content | :invalid_content | :unsafe_content

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
    case classify_content(content) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_message}
    end
  rescue
    _error -> {:error, :invalid_message}
  catch
    _kind, _reason -> {:error, :invalid_message}
  end

  @doc "Classifies output content using fixed non-content-bearing reasons."
  @spec classify_content(term()) :: :ok | {:error, content_error()}
  def classify_content(content) when is_binary(content) do
    cond do
      byte_size(content) == 0 -> {:error, :blank_content}
      byte_size(content) > @max_content_bytes -> {:error, :invalid_content}
      not String.valid?(content) -> {:error, :invalid_content}
      blank?(content) -> {:error, :blank_content}
      unsafe_output?(content) -> {:error, :unsafe_content}
      true -> :ok
    end
  rescue
    _error -> {:error, :invalid_content}
  catch
    _kind, _reason -> {:error, :invalid_content}
  end

  def classify_content(_content), do: {:error, :invalid_content}

  defp exact_message?(message) do
    map_size(message) == @message_key_count and
      Enum.all?(@message_keys, &Map.has_key?(message, &1))
  end

  defp valid_portable_id?(value)
       when is_binary(value) and byte_size(value) in 1..@max_id_bytes do
    String.valid?(value) and Regex.match?(@id_pattern, value)
  end

  defp valid_portable_id?(_value), do: false

  defp valid_content?(content), do: classify_content(content) == :ok

  defp blank?(content) do
    content
    |> String.normalize(:nfkc)
    |> then(&(not Regex.match?(@visible_content_pattern, &1)))
  end

  defp unsafe_output?(content) do
    normalized = String.normalize(content, :nfkc)
    network_normalized = Regex.replace(@unicode_dot_pattern, normalized, ".")

    domain_normalized = normalize_domain_scan(normalized)

    Regex.match?(@forbidden_control_pattern, network_normalized) or
      Regex.match?(@forbidden_scheme_pattern, network_normalized) or
      Regex.match?(@forbidden_network_path_pattern, network_normalized) or
      domain_like?(domain_normalized) or
      Regex.match?(@forbidden_ip_pattern, network_normalized) or
      Regex.match?(@forbidden_mention_pattern, network_normalized)
  end

  defp normalize_domain_scan(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn line ->
      if japanese_sentence_chain?(line),
        do: Regex.replace(@unicode_dot_pattern, line, " "),
        else: Regex.replace(@unicode_dot_pattern, line, ".")
    end)
  end

  defp japanese_sentence_chain?(line) do
    clauses = line |> String.trim() |> String.split("。", trim: false)

    case Enum.split(clauses, -1) do
      {completed, [""]} when length(completed) >= 2 ->
        Enum.all?(completed, &japanese_sentence_clause?/1)

      _other ->
        false
    end
  end

  defp japanese_sentence_clause?(clause) do
    Regex.match?(@japanese_sentence_body_pattern, clause) and
      Enum.any?(@japanese_sentence_endings, &String.ends_with?(clause, &1)) and
      Enum.all?(@japanese_reference_cues, &(not String.contains?(clause, &1)))
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

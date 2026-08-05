defmodule ClusterMurmur.Generation.ContextValidator do
  @moduledoc """
  Validates separated bounded generation inputs before prompt assembly.
  """

  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Generation.{
    Context,
    ConversationLine,
    CreativeContext,
    FactProjectionValidator,
    PersonaProjectionValidator
  }

  @context_keys Context.__struct__() |> Map.keys()
  @context_key_count length(@context_keys)
  @creative_keys CreativeContext.__struct__() |> Map.keys()
  @creative_key_count length(@creative_keys)
  @line_keys ConversationLine.__struct__() |> Map.keys()
  @line_key_count length(@line_keys)
  @kind_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @single_line_control_pattern ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\x{2028}\x{2029}]/u
  @content_control_pattern ~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}]/u
  @max_kind_bytes 128
  @max_mood_bytes 128
  @max_speaker_bytes 128
  @max_content_bytes 16 * 1_024
  @max_lines 12
  @max_context_bytes 128 * 1_024

  @type error :: :invalid_generation_context

  @doc "Validates one exact context and its aggregate text boundary."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%Context{} = context) do
    with true <- exact?(context, @context_keys, @context_key_count),
         :ok <- PersonaProjectionValidator.validate(context.persona),
         :ok <- FactProjectionValidator.validate(context.facts),
         {:ok, fact_bytes} <- FactProjectionValidator.serialized_size(context.facts),
         :ok <- validate_creative_context(context.creative_context),
         {:ok, history_bytes} <- validate_conversation(context.conversation),
         true <- aggregate_bytes(context, fact_bytes, history_bytes) <= @max_context_bytes do
      :ok
    else
      _failure -> {:error, :invalid_generation_context}
    end
  rescue
    _error -> {:error, :invalid_generation_context}
  catch
    _kind, _reason -> {:error, :invalid_generation_context}
  end

  def validate(_context), do: {:error, :invalid_generation_context}

  defp validate_creative_context(%CreativeContext{} = creative) do
    if exact?(creative, @creative_keys, @creative_key_count) and
         valid_kind?(creative.conversation_kind) and valid_mood?(creative.mood),
       do: :ok,
       else: {:error, :invalid_generation_context}
  end

  defp validate_creative_context(_creative), do: {:error, :invalid_generation_context}

  defp validate_conversation(lines) when is_list(lines),
    do: validate_conversation(lines, nil, 0, 0)

  defp validate_conversation(_lines), do: {:error, :invalid_generation_context}

  defp validate_conversation([], _previous_at, _count, bytes), do: {:ok, bytes}

  defp validate_conversation([_line | _lines], _previous_at, @max_lines, _bytes),
    do: {:error, :invalid_generation_context}

  defp validate_conversation(
         [%ConversationLine{} = line | lines],
         previous_at,
         count,
         bytes
       ) do
    if exact?(line, @line_keys, @line_key_count) and valid_speaker?(line.speaker) and
         valid_content?(line.content) and valid_datetime?(line.inserted_at) and
         ordered_after?(line.inserted_at, previous_at) do
      validate_conversation(
        lines,
        line.inserted_at,
        count + 1,
        bytes + byte_size(line.speaker) + byte_size(line.content)
      )
    else
      {:error, :invalid_generation_context}
    end
  end

  defp validate_conversation(_improper, _previous_at, _count, _bytes),
    do: {:error, :invalid_generation_context}

  defp aggregate_bytes(context, fact_bytes, history_bytes) do
    fact_bytes + history_bytes + byte_size(context.persona.display_name) +
      byte_size(context.persona.instructions) +
      byte_size(context.creative_context.conversation_kind) +
      byte_size(context.creative_context.mood)
  end

  defp exact?(value, keys, key_count) do
    map_size(value) == key_count and Enum.all?(keys, &Map.has_key?(value, &1))
  end

  defp valid_kind?(value)
       when is_binary(value) and byte_size(value) in 1..@max_kind_bytes,
       do: String.valid?(value) and Regex.match?(@kind_pattern, value)

  defp valid_kind?(_value), do: false

  defp valid_mood?(value) when is_binary(value) and byte_size(value) in 1..@max_mood_bytes,
    do: valid_single_line_text?(value)

  defp valid_mood?(_value), do: false

  defp valid_speaker?(value)
       when is_binary(value) and byte_size(value) in 1..@max_speaker_bytes,
       do: valid_single_line_text?(value)

  defp valid_speaker?(_value), do: false

  defp valid_content?(value)
       when is_binary(value) and byte_size(value) in 1..@max_content_bytes,
       do: valid_content_text?(value)

  defp valid_content?(_value), do: false

  defp valid_single_line_text?(value) do
    String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(@single_line_control_pattern, value)
  end

  defp valid_content_text?(value) do
    String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(@content_control_pattern, value)
  end

  defp valid_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp ordered_after?(_inserted_at, nil), do: true

  defp ordered_after?(inserted_at, previous_at),
    do: DateTime.compare(inserted_at, previous_at) in [:gt, :eq]
end

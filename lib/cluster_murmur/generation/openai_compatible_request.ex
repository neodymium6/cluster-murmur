defmodule ClusterMurmur.Generation.OpenAICompatibleRequest do
  @moduledoc """
  Encodes one fixed bounded OpenAI-compatible chat-completions request.

  The complete provider-neutral prompt and loaded settings are revalidated at
  this boundary. The resulting redacted value contains no caller-controlled
  method, path, headers, transport limits, or extra JSON fields.
  """

  alias ClusterMurmur.DomainLimits

  alias ClusterMurmur.Generation.{
    FactProjection,
    FactProjectionValidator,
    PersonaProjection,
    PersonaProjectionValidator,
    PromptAssembler,
    PromptRequest,
    ProviderSettings
  }

  @content_type {"content-type", "application/json"}
  @connect_timeout_ms 5_000
  @max_response_bytes 64 * 1_024
  @max_request_bytes 1_024 * 1_024
  @max_nodes 1_024
  @max_depth 8
  @max_collection_entries 256
  @max_string_bytes 64 * 1_024
  @max_total_text_bytes 128 * 1_024
  @single_line_control_pattern ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\x{2028}\x{2029}]/u
  @content_control_pattern ~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}]/u
  @kind_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @prompt_keys PromptRequest.__struct__() |> Map.keys()
  @prompt_key_count length(@prompt_keys)
  @persona_keys ["display_name", "instructions"]
  @fact_keys [
    "current_state",
    "details",
    "event_type",
    "group",
    "occurred_at",
    "previous_state",
    "severity",
    "subject"
  ]
  @creative_keys ["conversation_kind", "mood"]
  @conversation_line_keys ["content", "speaker"]

  @derive {Inspect,
           only: [
             :method,
             :connect_timeout_ms,
             :receive_timeout_ms,
             :overall_timeout_ms,
             :max_response_bytes
           ]}
  @enforce_keys [
    :method,
    :url,
    :headers,
    :json,
    :connect_timeout_ms,
    :receive_timeout_ms,
    :overall_timeout_ms,
    :max_response_bytes
  ]
  defstruct [
    :method,
    :url,
    :headers,
    :json,
    :connect_timeout_ms,
    :receive_timeout_ms,
    :overall_timeout_ms,
    :max_response_bytes
  ]

  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | map()
  @type t :: %__MODULE__{
          method: :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          json: %{String.t() => json_value()},
          connect_timeout_ms: pos_integer(),
          receive_timeout_ms: pos_integer(),
          overall_timeout_ms: pos_integer(),
          max_response_bytes: pos_integer()
        }
  @type error :: :invalid_prompt_request | :invalid_provider_settings | :invalid_provider_request

  @doc "Returns the fixed maximum response bytes an adapter may accept."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc "Encodes an exact prompt and settings value without performing transport."
  @spec encode(term(), term()) :: {:ok, t()} | {:error, error()}
  def encode(%PromptRequest{} = prompt, %ProviderSettings{} = settings) do
    with :ok <- validate_prompt(prompt),
         :ok <- ProviderSettings.validate(settings),
         json <- request_json(prompt, settings),
         true <- encoded_size(json) <= @max_request_bytes do
      {:ok,
       %__MODULE__{
         method: :post,
         url: String.trim_trailing(settings.base_url, "/") <> "/chat/completions",
         headers: [@content_type, {"authorization", "Bearer " <> settings.api_key}],
         json: json,
         connect_timeout_ms: min(@connect_timeout_ms, settings.timeout_ms),
         receive_timeout_ms: settings.timeout_ms,
         overall_timeout_ms: settings.timeout_ms,
         max_response_bytes: @max_response_bytes
       }}
    else
      {:error, :invalid_provider_settings} = error -> error
      _failure -> {:error, :invalid_prompt_request}
    end
  rescue
    _error -> {:error, :invalid_prompt_request}
  catch
    _kind, _reason -> {:error, :invalid_prompt_request}
  end

  def encode(_prompt, _settings), do: {:error, :invalid_prompt_request}

  @doc "Rebuilds and compares every request field immediately before transport."
  @spec validate(term(), term(), term()) :: :ok | {:error, error()}
  def validate(request, prompt, settings) do
    case encode(prompt, settings) do
      {:ok, expected} when request == expected -> :ok
      {:ok, _expected} -> {:error, :invalid_provider_request}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :invalid_provider_request}
  catch
    _kind, _reason -> {:error, :invalid_provider_request}
  end

  defp validate_prompt(prompt) do
    data = prompt_data(prompt)

    with true <- exact_map?(prompt, @prompt_keys, @prompt_key_count),
         true <- prompt.system_instruction == PromptAssembler.system_instruction(),
         true <- valid_persona?(prompt.persona),
         true <- valid_facts?(prompt.confirmed_facts),
         true <- valid_creative_context?(prompt.creative_context),
         true <- valid_conversation?(prompt.conversation),
         {:ok, _nodes, text_bytes} <- validate_tree(data, 0, 0, 0),
         true <- text_bytes <= @max_total_text_bytes do
      :ok
    else
      _failure -> {:error, :invalid_prompt_request}
    end
  end

  defp valid_conversation?(conversation) when is_list(conversation),
    do: valid_conversation?(conversation, 0)

  defp valid_conversation?(_conversation), do: false

  defp valid_conversation?([], _count), do: true

  defp valid_conversation?([line | lines], count) when count < 12,
    do: valid_conversation_line?(line) and valid_conversation?(lines, count + 1)

  defp valid_conversation?(_conversation, _count), do: false

  defp valid_persona?(value) do
    if exact_map_keys?(value, @persona_keys) do
      PersonaProjectionValidator.validate(%PersonaProjection{
        display_name: value["display_name"],
        instructions: value["instructions"]
      }) == :ok
    else
      false
    end
  end

  defp valid_facts?(value) do
    with true <- exact_map_keys?(value, @fact_keys),
         {:ok, occurred_at} <- parse_occurred_at(value["occurred_at"]),
         projection = %FactProjection{
           event_type: value["event_type"],
           subject: value["subject"],
           group: value["group"],
           severity: value["severity"],
           previous_state: value["previous_state"],
           current_state: value["current_state"],
           details: value["details"],
           occurred_at: occurred_at
         },
         {:ok, expected} <- FactProjectionValidator.to_prompt_map(projection) do
      expected == value
    else
      _failure -> false
    end
  end

  defp parse_occurred_at(value)
       when is_binary(value) and byte_size(value) in 1..64 do
    if String.valid?(value) do
      case DateTime.from_iso8601(value) do
        {:ok, occurred_at, 0} -> {:ok, occurred_at}
        _invalid -> {:error, :invalid_prompt_request}
      end
    else
      {:error, :invalid_prompt_request}
    end
  end

  defp parse_occurred_at(_value), do: {:error, :invalid_prompt_request}

  defp valid_creative_context?(value) do
    exact_map_keys?(value, @creative_keys) and
      valid_kind?(value["conversation_kind"]) and valid_mood?(value["mood"])
  end

  defp valid_conversation_line?(value) do
    exact_map_keys?(value, @conversation_line_keys) and valid_speaker?(value["speaker"]) and
      valid_content?(value["content"])
  end

  defp exact_map_keys?(value, keys) when is_map(value) and not is_struct(value),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))

  defp exact_map_keys?(_value, _keys), do: false

  defp exact_map?(value, keys, count),
    do: is_map(value) and map_size(value) == count and Enum.all?(keys, &Map.has_key?(value, &1))

  defp request_json(prompt, settings) do
    %{
      "max_tokens" => settings.max_output_tokens,
      "messages" => [
        %{"content" => prompt.system_instruction, "role" => "system"},
        %{"content" => encode_json(prompt_data(prompt)), "role" => "user"}
      ],
      "model" => settings.model
    }
  end

  defp prompt_data(prompt) do
    %{
      "confirmed_facts" => prompt.confirmed_facts,
      "conversation" => prompt.conversation,
      "creative_context" => prompt.creative_context,
      "persona" => prompt.persona
    }
  end

  defp encoded_size(value), do: value |> :json.encode() |> IO.iodata_length()
  defp encode_json(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  defp validate_tree(_value, _depth, nodes, _text_bytes) when nodes >= @max_nodes,
    do: {:error, :invalid_prompt_request}

  defp validate_tree(value, _depth, nodes, text_bytes)
       when is_nil(value) or is_boolean(value),
       do: {:ok, nodes + 1, text_bytes}

  defp validate_tree(value, _depth, nodes, text_bytes) when is_integer(value) do
    if value in -DomainLimits.max_safe_integer()..DomainLimits.max_safe_integer(),
      do: {:ok, nodes + 1, text_bytes},
      else: {:error, :invalid_prompt_request}
  end

  defp validate_tree(value, _depth, nodes, text_bytes) when is_float(value) do
    if value == value and value >= -DomainLimits.max_float() and
         value <= DomainLimits.max_float(),
       do: {:ok, nodes + 1, text_bytes},
       else: {:error, :invalid_prompt_request}
  end

  defp validate_tree(value, _depth, nodes, text_bytes) when is_binary(value) do
    next_text_bytes = text_bytes + byte_size(value)

    if valid_string?(value) and next_text_bytes <= @max_total_text_bytes,
      do: {:ok, nodes + 1, next_text_bytes},
      else: {:error, :invalid_prompt_request}
  end

  defp validate_tree(value, depth, nodes, text_bytes)
       when is_map(value) and not is_struct(value) and depth < @max_depth and
              map_size(value) <= @max_collection_entries do
    Enum.reduce_while(value, {:ok, nodes + 1, text_bytes}, fn {key, nested},
                                                              {:ok, next_nodes, next_text_bytes} ->
      with true <- valid_key?(key),
           {:ok, next_nodes, next_text_bytes} <-
             validate_tree(key, depth + 1, next_nodes, next_text_bytes),
           {:ok, next_nodes, next_text_bytes} <-
             validate_tree(nested, depth + 1, next_nodes, next_text_bytes) do
        {:cont, {:ok, next_nodes, next_text_bytes}}
      else
        _failure -> {:halt, {:error, :invalid_prompt_request}}
      end
    end)
  end

  defp validate_tree(value, depth, nodes, text_bytes)
       when is_list(value) and depth < @max_depth and length(value) <= @max_collection_entries do
    Enum.reduce_while(value, {:ok, nodes + 1, text_bytes}, fn nested,
                                                              {:ok, next_nodes, next_text_bytes} ->
      case validate_tree(nested, depth + 1, next_nodes, next_text_bytes) do
        {:ok, next_nodes, next_text_bytes} ->
          {:cont, {:ok, next_nodes, next_text_bytes}}

        {:error, :invalid_prompt_request} = error ->
          {:halt, error}
      end
    end)
  end

  defp validate_tree(_value, _depth, _nodes, _text_bytes),
    do: {:error, :invalid_prompt_request}

  defp valid_key?(value), do: is_binary(value) and byte_size(value) in 1..512

  defp valid_kind?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.valid?(value) and Regex.match?(@kind_pattern, value)

  defp valid_kind?(_value), do: false

  defp valid_mood?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: valid_single_line_text?(value)

  defp valid_mood?(_value), do: false

  defp valid_speaker?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: valid_single_line_text?(value)

  defp valid_speaker?(_value), do: false

  defp valid_content?(value)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= 16 * 1_024 do
    String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(@content_control_pattern, value)
  end

  defp valid_content?(_value), do: false

  defp valid_single_line_text?(value) do
    String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(@single_line_control_pattern, value)
  end

  defp valid_string?(value) do
    byte_size(value) <= @max_string_bytes and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end
end

defmodule ClusterMurmur.Generation.OpenAICompatibleResponse do
  @moduledoc """
  Decodes one bounded OpenAI-compatible response into text or a stable error.

  Raw bodies and provider diagnostics never cross this boundary. Successful
  response JSON passes the shared bounded decoder before this module extracts
  only the single message content requested by the application.
  """

  alias ClusterMurmur.Events.BoundedJsonDecoder
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.ExternalError
  alias ClusterMurmur.Generation.OpenAICompatibleRequest

  @derive {Inspect, only: [:status]}
  @enforce_keys [:status, :body]
  defstruct [:status, :body]

  @response_keys [:__struct__, :body, :status]
  @response_key_count length(@response_keys)
  @finish_reasons %{
    "content_filter" => :content_filter,
    "function_call" => :function_call,
    "length" => :length,
    "stop" => :stop,
    "tool_calls" => :tool_calls
  }
  @max_safe_integer DomainLimits.max_safe_integer()

  @type t :: %__MODULE__{status: integer(), body: binary()}
  @type result :: {:ok, String.t()} | {:error, ExternalError.t()}

  @doc "Classifies one exact bounded response without exposing its raw body."
  @spec decode(term()) :: result()
  def decode(%__MODULE__{} = response) do
    if exact_bounded_response?(response),
      do: decode_status(response.status, response.body),
      else: {:error, :invalid_response}
  rescue
    _error -> {:error, :invalid_response}
  catch
    _kind, _reason -> {:error, :invalid_response}
  end

  def decode(_response), do: {:error, :invalid_response}

  defp exact_bounded_response?(response) do
    map_size(response) == @response_key_count and
      Enum.all?(@response_keys, &Map.has_key?(response, &1)) and
      is_integer(response.status) and response.status in 100..599 and
      is_binary(response.body) and
      byte_size(response.body) <= OpenAICompatibleRequest.max_response_bytes()
  end

  defp decode_status(200, body), do: decode_success(body)

  defp decode_status(status, _body) when status in [401, 403],
    do: {:error, :authentication_failed}

  defp decode_status(408, _body), do: {:error, :timeout}
  defp decode_status(429, _body), do: {:error, :rate_limited}
  defp decode_status(status, _body) when status in 400..499, do: {:error, :invalid_request}
  defp decode_status(status, _body) when status in 500..599, do: {:error, :unavailable}
  defp decode_status(_status, _body), do: {:error, :invalid_response}

  defp decode_success(body) do
    with {:ok, budget} <- BoundedJsonDecoder.initial_budget([]),
         {:ok, decoded, _remaining_budget} <- BoundedJsonDecoder.decode(body, budget),
         {:ok, completion} <- extract_completion(decoded) do
      classify_completion(completion)
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp extract_completion(%{"choices" => [choice]} = decoded) when is_map(choice) do
    with {:ok, content} <- extract_content(choice),
         {:ok, finish_reason} <- extract_finish_reason(choice),
         {:ok, completion_tokens, reasoning_tokens} <- extract_usage(decoded) do
      {:ok,
       %{
         content: content,
         finish_reason: finish_reason,
         completion_tokens: completion_tokens,
         reasoning_tokens: reasoning_tokens
       }}
    end
  end

  defp extract_completion(_decoded), do: {:error, :invalid_response}

  defp extract_content(%{"message" => %{"content" => content}})
       when is_binary(content) or is_nil(content),
       do: {:ok, content}

  defp extract_content(_choice), do: {:error, :invalid_response}

  defp extract_finish_reason(choice) do
    case Map.fetch(choice, "finish_reason") do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> Map.fetch(@finish_reasons, value)
      {:ok, _invalid} -> {:error, :invalid_response}
    end
  end

  defp extract_usage(decoded) do
    case Map.fetch(decoded, "usage") do
      :error -> {:ok, nil, nil}
      {:ok, nil} -> {:ok, nil, nil}
      {:ok, usage} when is_map(usage) -> extract_usage_tokens(usage)
      {:ok, _invalid} -> {:error, :invalid_response}
    end
  end

  defp extract_usage_tokens(usage) do
    with {:ok, completion_tokens} <- optional_nonnegative_integer(usage, "completion_tokens"),
         {:ok, reasoning_tokens} <- extract_reasoning_tokens(usage),
         true <-
           is_nil(completion_tokens) or is_nil(reasoning_tokens) or
             reasoning_tokens <= completion_tokens do
      {:ok, completion_tokens, reasoning_tokens}
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp extract_reasoning_tokens(usage) do
    case Map.fetch(usage, "completion_tokens_details") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, details} when is_map(details) ->
        optional_nonnegative_integer(details, "reasoning_tokens")

      {:ok, _invalid} ->
        {:error, :invalid_response}
    end
  end

  defp optional_nonnegative_integer(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_integer(value) and value in 0..@max_safe_integer -> {:ok, value}
      {:ok, _invalid} -> {:error, :invalid_response}
    end
  end

  defp classify_completion(%{content: content, finish_reason: :length})
       when is_nil(content),
       do: {:error, :token_exhausted}

  defp classify_completion(%{content: content, finish_reason: :length})
       when is_binary(content) do
    if String.trim(content) == "", do: {:error, :token_exhausted}, else: {:ok, content}
  end

  defp classify_completion(%{content: content}) when is_binary(content), do: {:ok, content}

  defp classify_completion(_completion), do: {:error, :invalid_response}
end

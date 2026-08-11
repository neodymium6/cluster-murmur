defmodule ClusterMurmur.Observers.MCPHTTPResponse do
  @moduledoc """
  Decodes one bounded MCP 2026-07-28 Streamable HTTP response.

  JSON and request-scoped SSE envelopes remain inside this boundary. Only the
  structured result for the fixed request identifier enters the application;
  notifications, protocol diagnostics, and raw response bodies are discarded.
  """

  alias ClusterMurmur.Events.BoundedJsonDecoder
  alias ClusterMurmur.Observers.{MCPRequest, MCPResponse}

  @json_rpc_id 1
  @formats [:json, :event_stream]
  @invalid_request_error_codes [-32_700, -32_600, -32_601, -32_602, -32_020]

  @derive {Inspect, only: [:status, :format]}
  @enforce_keys [:status, :format, :body]
  defstruct [:status, :format, :body]

  @response_keys [:__struct__, :body, :format, :status]
  @response_key_count length(@response_keys)

  @type format :: :json | :event_stream
  @type t :: %__MODULE__{status: integer(), format: format(), body: binary()}
  @type result ::
          {:ok, MCPResponse.t()}
          | {:error, :rejected, :authentication_failed | :invalid_request | :rate_limited}
          | {:error, :outcome_unknown}
          | {:error, :invalid_response}

  @doc "Decodes one exact bounded HTTP response into the injected transport contract."
  @spec decode(term()) :: result()
  def decode(%__MODULE__{} = response) do
    if exact_bounded_response?(response),
      do: decode_status(response.status, response.format, response.body),
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
      response.format in @formats and is_binary(response.body) and
      byte_size(response.body) <= MCPRequest.max_response_bytes()
  end

  defp decode_status(200, :json, body) do
    with {:ok, budget} <- BoundedJsonDecoder.initial_budget([]),
         {:ok, decoded, _budget} <- BoundedJsonDecoder.decode(body, budget) do
      decode_final_message(decoded)
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp decode_status(200, :event_stream, body), do: decode_event_stream(body)

  defp decode_status(status, _format, _body) when status in [401, 403],
    do: {:error, :rejected, :authentication_failed}

  defp decode_status(429, _format, _body), do: {:error, :rejected, :rate_limited}

  defp decode_status(408, _format, _body), do: {:error, :outcome_unknown}

  defp decode_status(status, _format, _body) when status in 400..499,
    do: {:error, :rejected, :invalid_request}

  defp decode_status(status, _format, _body) when status in 500..599,
    do: {:error, :outcome_unknown}

  defp decode_status(_status, _format, _body), do: {:error, :invalid_response}

  defp decode_event_stream(body) do
    with {:ok, events} <- event_data(body),
         {:ok, budget} <- BoundedJsonDecoder.initial_budget([]) do
      decode_events(events, budget)
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp event_data(body) do
    body
    |> String.split(~r/\r\n|\r|\n/, trim: false)
    |> collect_event_data([], [])
  end

  defp collect_event_data([], current, events),
    do: {:ok, finish_event(current, events) |> Enum.reverse()}

  defp collect_event_data(["" | lines], current, events),
    do: collect_event_data(lines, [], finish_event(current, events))

  defp collect_event_data([":" <> _comment | lines], current, events),
    do: collect_event_data(lines, current, events)

  defp collect_event_data([line | lines], current, events) do
    case String.split(line, ":", parts: 2) do
      ["data", value] -> collect_event_data(lines, [strip_space(value) | current], events)
      ["data"] -> collect_event_data(lines, ["" | current], events)
      [_ignored_field, _value] -> collect_event_data(lines, current, events)
      [_ignored_field] -> collect_event_data(lines, current, events)
    end
  end

  defp finish_event([], events), do: events

  defp finish_event(data_lines, events),
    do: [data_lines |> Enum.reverse() |> Enum.join("\n") | events]

  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value

  defp decode_events([], _budget), do: {:error, :invalid_response}

  defp decode_events([encoded | remaining], budget) do
    with {:ok, decoded, next_budget} <- BoundedJsonDecoder.decode(encoded, budget) do
      case classify_message(decoded) do
        :notification -> decode_events(remaining, next_budget)
        {:final, result} when remaining == [] -> result
        {:final, _result} -> {:error, :invalid_response}
        :invalid -> {:error, :invalid_response}
      end
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp classify_message(%{"jsonrpc" => "2.0", "method" => method} = notification)
       when is_binary(method) do
    if valid_notification?(notification, method),
      do: :notification,
      else: :invalid
  end

  defp classify_message(message), do: {:final, decode_final_message(message)}

  defp decode_final_message(
         %{"id" => @json_rpc_id, "jsonrpc" => "2.0", "result" => result} = envelope
       )
       when map_size(envelope) == 3 and is_map(result) do
    with "complete" <- Map.get(result, "resultType"),
         content when is_list(content) <- Map.get(result, "content"),
         false <- Map.get(result, "isError", false),
         true <- Map.has_key?(result, "structuredContent"),
         {:ok, body} <- encode_structured_content(result["structuredContent"]) do
      {:ok, %MCPResponse{body: body}}
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp decode_final_message(
         %{"id" => @json_rpc_id, "jsonrpc" => "2.0", "error" => error} = envelope
       )
       when map_size(envelope) == 3 and is_map(error) do
    classify_protocol_error(error)
  end

  defp decode_final_message(_message), do: {:error, :invalid_response}

  defp valid_notification?(notification, method) do
    valid_method?(method) and
      case notification do
        %{"jsonrpc" => "2.0", "method" => ^method} when map_size(notification) == 2 ->
          true

        %{"jsonrpc" => "2.0", "method" => ^method, "params" => params}
        when map_size(notification) == 3 and is_map(params) ->
          true

        _invalid ->
          false
      end
  end

  defp valid_method?(method),
    do: byte_size(method) in 1..512 and String.valid?(method)

  defp classify_protocol_error(%{"code" => code, "message" => message})
       when is_integer(code) and is_binary(message) and byte_size(message) in 1..16_384 do
    if code in @invalid_request_error_codes,
      do: {:error, :rejected, :invalid_request},
      else: {:error, :outcome_unknown}
  end

  defp classify_protocol_error(_error), do: {:error, :invalid_response}

  defp encode_structured_content(content) do
    body = content |> :json.encode() |> IO.iodata_to_binary()

    if byte_size(body) <= MCPRequest.max_response_bytes(),
      do: {:ok, body},
      else: {:error, :invalid_response}
  end
end

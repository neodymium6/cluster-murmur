defmodule ClusterMurmur.Observers.MCPHTTPResponseTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observers.{MCPHTTPResponse, MCPRequest, MCPResponse}

  test "extracts only structured content from one JSON response" do
    response = response(:json, envelope(%{"targets" => []}))

    assert {:ok, %MCPResponse{} = decoded} = MCPHTTPResponse.decode(response)
    assert :json.decode(decoded.body) == %{"targets" => []}
    refute inspect(response) =~ response.body
  end

  test "ignores bounded SSE notifications before the final response" do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"progress" => 1}
    }

    body =
      ": keep-alive\r\n" <>
        "event: message\r\n" <>
        "data: #{json(notification)}\r\n\r\n" <>
        "event: message\n" <>
        "data: #{json(envelope(%{"targets" => []}))}\n\n"

    assert {:ok, %MCPResponse{body: decoded}} =
             MCPHTTPResponse.decode(response(:event_stream, body))

    assert :json.decode(decoded) == %{"targets" => []}
  end

  test "joins multiline SSE data and requires the final response to be last" do
    encoded = json(envelope(%{"targets" => []}))
    [first, second] = String.split(encoded, ",", parts: 2)

    assert {:ok, %MCPResponse{}} =
             MCPHTTPResponse.decode(
               response(:event_stream, "data: #{first},\ndata:#{second}\n\n")
             )

    trailing = "data: #{encoded}\n\ndata: #{json(%{"jsonrpc" => "2.0", "method" => "note"})}\n\n"

    assert MCPHTTPResponse.decode(response(:event_stream, trailing)) ==
             {:error, :invalid_response}
  end

  test "maps only stable HTTP and protocol failures" do
    cases = [
      {401, {:error, :rejected, :authentication_failed}},
      {403, {:error, :rejected, :authentication_failed}},
      {400, {:error, :rejected, :invalid_request}},
      {404, {:error, :rejected, :invalid_request}},
      {429, {:error, :rejected, :rate_limited}},
      {408, {:error, :outcome_unknown}},
      {500, {:error, :outcome_unknown}},
      {503, {:error, :outcome_unknown}},
      {204, {:error, :invalid_response}}
    ]

    for {status, expected} <- cases do
      result = MCPHTTPResponse.decode(response(:json, "private diagnostic", status))
      assert result == expected
      refute inspect(result) =~ "private"
    end

    protocol_error = %{
      "error" => %{"code" => -32_602, "message" => "private diagnostic"},
      "id" => 1,
      "jsonrpc" => "2.0"
    }

    assert MCPHTTPResponse.decode(response(:json, protocol_error)) ==
             {:error, :rejected, :invalid_request}

    for code <- [-32_603, -32_001, 42] do
      server_error = put_in(protocol_error, ["error", "code"], code)
      assert MCPHTTPResponse.decode(response(:json, server_error)) == {:error, :outcome_unknown}
    end
  end

  test "rejects malformed, failed, mismatched, and oversized responses" do
    valid_result = %{
      "content" => [],
      "isError" => false,
      "resultType" => "complete",
      "structuredContent" => %{"targets" => []}
    }

    invalid_bodies = [
      "not json",
      Map.put(envelope(%{"targets" => []}), "id", 2),
      Map.put(envelope(%{"targets" => []}), "private", true),
      %{"id" => 1, "jsonrpc" => "2.0", "result" => %{valid_result | "isError" => true}},
      %{"id" => 1, "jsonrpc" => "2.0", "result" => Map.delete(valid_result, "content")},
      %{
        "id" => 1,
        "jsonrpc" => "2.0",
        "result" => Map.delete(valid_result, "structuredContent")
      },
      %{
        "id" => 1,
        "jsonrpc" => "2.0",
        "result" => %{valid_result | "resultType" => "input_required"}
      },
      %{"error" => %{"message" => "missing code"}, "id" => 1, "jsonrpc" => "2.0"}
    ]

    for body <- invalid_bodies do
      assert MCPHTTPResponse.decode(response(:json, body)) == {:error, :invalid_response}
    end

    final = json(envelope(%{"targets" => []}))

    for notification <- [
          %{"jsonrpc" => "2.0", "method" => "note", "unexpected" => true},
          %{"jsonrpc" => "2.0", "method" => "note", "params" => []},
          %{"jsonrpc" => "2.0", "method" => ""}
        ] do
      stream = "data: #{json(notification)}\n\ndata: #{final}\n\n"

      assert MCPHTTPResponse.decode(response(:event_stream, stream)) ==
               {:error, :invalid_response}
    end

    oversized = String.duplicate("x", MCPRequest.max_response_bytes() + 1)
    assert MCPHTTPResponse.decode(response(:json, oversized)) == {:error, :invalid_response}

    for invalid <- [
          %{response(:json, envelope(%{"targets" => []})) | format: :html},
          Map.put(response(:json, envelope(%{"targets" => []})), :private, true),
          nil
        ] do
      assert MCPHTTPResponse.decode(invalid) == {:error, :invalid_response}
    end
  end

  defp envelope(structured_content) do
    %{
      "id" => 1,
      "jsonrpc" => "2.0",
      "result" => %{
        "content" => [],
        "isError" => false,
        "resultType" => "complete",
        "structuredContent" => structured_content
      }
    }
  end

  defp response(format, body, status \\ 200) do
    body = if is_binary(body), do: body, else: json(body)
    %MCPHTTPResponse{status: status, format: format, body: body}
  end

  defp json(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end

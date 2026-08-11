defmodule ClusterMurmur.Observers.MCPHTTPTransportTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Observers.{MCPClient, MCPHTTPTransport, MCPRequest, MCPSettings}

  @token "clearly-fake-observer-token"

  test "executes one fixed JSON observer request over bounded loopback HTTP" do
    body = envelope(%{"targets" => []})
    {settings, request_task} = serve_once(200, "application/json; charset=utf-8", body)
    settings = %{settings | endpoint: String.replace(settings.endpoint, "127.0.0.1", "localhost")}

    transport = fn operation -> MCPHTTPTransport.execute(operation, settings) end
    assert MCPClient.list_targets(transport) == {:ok, []}

    assert {:ok, raw_request} = Task.await(request_task)
    assert raw_request =~ "POST /mcp HTTP/1.1\r\n"
    assert String.downcase(raw_request) =~ "authorization: bearer " <> @token
    assert String.downcase(raw_request) =~ "mcp-method: tools/call"
    assert String.downcase(raw_request) =~ "mcp-name: observer_list_targets"
    assert String.downcase(raw_request) =~ "mcp-protocol-version: 2026-07-28"

    [_headers, encoded] = String.split(raw_request, "\r\n\r\n", parts: 2)
    assert :json.decode(encoded)["params"]["name"] == "observer_list_targets"
  end

  test "accepts request-scoped SSE and keeps stable rejection classes" do
    sse = "event: message\ndata: #{envelope(%{"targets" => []})}\n\n"
    {settings, request_task} = serve_once(200, "text/event-stream", sse)

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), settings) ==
             {:ok, %ClusterMurmur.Observers.MCPResponse{body: "{\"targets\":[]}"}}

    assert {:ok, _request} = Task.await(request_task)

    {rejected_settings, rejected_task} = serve_once(401, "text/plain", "private diagnostic")

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), rejected_settings) ==
             {:error, :rejected, :authentication_failed}

    assert {:ok, _request} = Task.await(rejected_task)

    {limited_settings, limited_task} = serve_once(429, "text/html", "private diagnostic")

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), limited_settings) ==
             {:error, :rejected, :rate_limited}

    assert {:ok, _request} = Task.await(limited_task)
  end

  test "rejects an invalid UTF-8 media type without raising" do
    invalid_media_type = <<"application/json; charset=", 255>>
    {settings, request_task} = serve_once(200, invalid_media_type, envelope(%{"targets" => []}))

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(request_task)
  end

  test "brackets an explicit IPv6 literal in the HTTP Host header" do
    case serve_once_ipv6(200, "application/json", envelope(%{"targets" => []})) do
      {:ok, settings, request_task} ->
        assert {:ok, %ClusterMurmur.Observers.MCPResponse{}} =
                 MCPHTTPTransport.execute(MCPRequest.list_targets(), settings)

        assert {:ok, raw_request} = Task.await(request_task)
        assert raw_request =~ ~r/\r\nhost: \[::1\]:[0-9]+\r\n/i

      {:error, reason} ->
        assert reason in [:eafnosupport, :eaddrnotavail]
    end
  end

  test "bounds wire bytes retained by the HTTP parser" do
    unterminated_status = "HTTP/1.1 200 " <> String.duplicate("x", 100 * 1_024)
    {settings, request_task} = serve_raw_once(unterminated_status)

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(request_task)
  end

  test "classifies an oversized response header as invalid" do
    oversized_header =
      "HTTP/1.1 200 OK\r\n" <>
        "content-type: application/json\r\n" <>
        "x-oversized: #{String.duplicate("x", 17 * 1_024)}\r\n\r\n"

    {settings, request_task} = serve_raw_once(oversized_header)

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(request_task)
  end

  test "closes oversized bodies and classifies pre-send failures" do
    oversized = String.duplicate("x", MCPRequest.max_response_bytes() + 1)
    {settings, request_task} = serve_once(200, "application/json", oversized, 1_024)

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(request_task)

    {:ok, listener} = listen()
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    unavailable = %MCPSettings{
      endpoint: "http://127.0.0.1:#{port}/mcp",
      bearer_token: @token
    }

    assert MCPHTTPTransport.execute(MCPRequest.list_targets(), unavailable) ==
             {:error, :not_sent, :unavailable}

    assert MCPHTTPTransport.execute(nil, unavailable) ==
             {:error, :rejected, :invalid_request}
  end

  defp serve_once(status, content_type, body, chunk_size \\ :all) do
    {:ok, listener} = listen()
    serve_on_listener(listener, "127.0.0.1", status, content_type, body, chunk_size)
  end

  defp serve_once_ipv6(status, content_type, body) do
    case listen({0, 0, 0, 0, 0, 0, 0, 1}) do
      {:ok, listener} ->
        {settings, task} = serve_on_listener(listener, "[::1]", status, content_type, body, :all)

        {:ok, settings, task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp serve_raw_once(response) do
    {:ok, listener} = listen()
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener),
             :ok <- :gen_tcp.close(listener),
             {:ok, request} <- receive_request(socket) do
          _sent = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
          {:ok, request}
        end
      end)

    settings = %MCPSettings{
      endpoint: "http://127.0.0.1:#{port}/mcp",
      bearer_token: @token
    }

    {settings, task}
  end

  defp serve_on_listener(listener, endpoint_host, status, content_type, body, chunk_size) do
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener),
             :ok <- :gen_tcp.close(listener),
             {:ok, request} <- receive_request(socket),
             :ok <- send_response(socket, status, content_type, body, chunk_size) do
          :gen_tcp.close(socket)
          {:ok, request}
        end
      end)

    settings = %MCPSettings{
      endpoint: "http://#{endpoint_host}:#{port}/mcp",
      bearer_token: @token
    }

    {settings, task}
  end

  defp listen(address \\ {127, 0, 0, 1})

  defp listen(address) when tuple_size(address) == 8,
    do: :gen_tcp.listen(0, [:binary, :inet6, active: false, ip: address, reuseaddr: true])

  defp listen(address),
    do: :gen_tcp.listen(0, [:binary, active: false, ip: address, reuseaddr: true])

  defp receive_request(socket, received \\ <<>>) do
    case :binary.split(received, "\r\n\r\n") do
      [headers, body] -> receive_request_body(socket, headers, body)
      [_incomplete] -> receive_more(socket, received)
    end
  end

  defp receive_more(socket, received) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> receive_request(socket, received <> data)
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_request_body(socket, headers, body) do
    with [length] <-
           Regex.run(~r/\r\ncontent-length: ([0-9]+)\r\n/i, "\r\n" <> headers <> "\r\n",
             capture: :all_but_first
           ),
         {length, ""} <- Integer.parse(length),
         {:ok, body} <- receive_body_bytes(socket, body, length) do
      {:ok, headers <> "\r\n\r\n" <> body}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp receive_body_bytes(_socket, body, length) when byte_size(body) == length,
    do: {:ok, body}

  defp receive_body_bytes(socket, body, length) when byte_size(body) < length do
    case :gen_tcp.recv(socket, length - byte_size(body), 5_000) do
      {:ok, data} -> receive_body_bytes(socket, body <> data, length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_body_bytes(_socket, _body, _length), do: {:error, :invalid_request}

  defp send_response(socket, status, content_type, body, chunk_size) do
    headers =
      [
        "HTTP/1.1 #{status} Test\r\n",
        if(content_type, do: "content-type: #{content_type}\r\n", else: []),
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n\r\n"
      ]

    with :ok <- :gen_tcp.send(socket, headers) do
      send_chunks(socket, body, chunk_size)
    end
  end

  defp send_chunks(socket, body, :all), do: :gen_tcp.send(socket, body)
  defp send_chunks(_socket, <<>>, _chunk_size), do: :ok

  defp send_chunks(socket, body, chunk_size) do
    size = min(byte_size(body), chunk_size)
    <<chunk::binary-size(size), remaining::binary>> = body

    with :ok <- :gen_tcp.send(socket, chunk) do
      send_chunks(socket, remaining, chunk_size)
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
    |> :json.encode()
    |> IO.iodata_to_binary()
  end
end

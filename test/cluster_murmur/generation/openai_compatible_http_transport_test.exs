defmodule ClusterMurmur.Generation.OpenAICompatibleHTTPTransportTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Generation.{
    OpenAICompatibleHTTPTransport,
    OpenAICompatibleProvider,
    OpenAICompatibleRequest,
    OpenAICompatibleResponse,
    PromptAssembler,
    PromptRequest,
    ProviderSettings
  }

  @api_key "clearly-fake-api-key"

  test "executes one fixed JSON generation request over bounded loopback HTTP" do
    body = success_body("The latest run completed.")
    {settings, request_task} = serve_once(200, "application/json; charset=utf-8", body)
    settings = %{settings | base_url: String.replace(settings.base_url, "127.0.0.1", "localhost")}
    settings = %{settings | reasoning_effort: :low}
    prompt = prompt()
    transport = fn request -> OpenAICompatibleHTTPTransport.execute(request, settings) end

    assert OpenAICompatibleProvider.generate(prompt, settings, transport) ==
             {:ok, "The latest run completed."}

    assert {:ok, raw_request} = Task.await(request_task)
    assert raw_request =~ "POST /v1/chat/completions HTTP/1.1\r\n"
    assert String.downcase(raw_request) =~ "authorization: bearer " <> @api_key
    assert String.downcase(raw_request) =~ "content-type: application/json"

    [_headers, encoded] = String.split(raw_request, "\r\n\r\n", parts: 2)
    decoded = :json.decode(encoded)
    assert decoded["model"] == "example-model"
    assert decoded["max_completion_tokens"] == 300
    assert decoded["reasoning_effort"] == "low"
    refute Map.has_key?(decoded, "max_tokens")
  end

  test "requires JSON only for successful responses" do
    prompt = prompt()
    {settings, rejected_task} = serve_once(401, "text/plain", "private diagnostic")
    {:ok, request} = OpenAICompatibleRequest.encode(prompt, settings)

    assert OpenAICompatibleHTTPTransport.execute(request, settings) ==
             {:ok, %OpenAICompatibleResponse{status: 401, body: "private diagnostic"}}

    assert {:ok, _request} = Task.await(rejected_task)

    {settings, invalid_task} = serve_once(200, "text/plain", success_body("unexpected"))
    {:ok, request} = OpenAICompatibleRequest.encode(prompt, settings)

    assert OpenAICompatibleHTTPTransport.execute(request, settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(invalid_task)
  end

  test "bounds body, raw wire, and header parser input" do
    prompt = prompt()
    oversized = String.duplicate("x", OpenAICompatibleRequest.max_response_bytes() + 1)
    {settings, body_task} = serve_once(200, "application/json", oversized, 1_024)
    {:ok, request} = OpenAICompatibleRequest.encode(prompt, settings)

    assert OpenAICompatibleHTTPTransport.execute(request, settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(body_task)

    unterminated_status = "HTTP/1.1 200 " <> String.duplicate("x", 100 * 1_024)
    {settings, wire_task} = serve_raw_once(unterminated_status)
    {:ok, request} = OpenAICompatibleRequest.encode(prompt, settings)

    assert OpenAICompatibleHTTPTransport.execute(request, settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(wire_task)

    oversized_header =
      "HTTP/1.1 200 OK\r\n" <>
        "content-type: application/json\r\n" <>
        "x-oversized: #{String.duplicate("x", 17 * 1_024)}\r\n\r\n"

    {settings, header_task} = serve_raw_once(oversized_header)
    {:ok, request} = OpenAICompatibleRequest.encode(prompt, settings)

    assert OpenAICompatibleHTTPTransport.execute(request, settings) ==
             {:error, :invalid_response}

    assert {:ok, _request} = Task.await(header_task)
  end

  test "brackets an explicit IPv6 literal in the HTTP Host header" do
    case serve_once_ipv6(200, "application/json", success_body("Hello.")) do
      {:ok, settings, request_task} ->
        prompt = prompt()
        {:ok, request} = OpenAICompatibleRequest.encode(prompt, settings)

        assert {:ok, %OpenAICompatibleResponse{status: 200}} =
                 OpenAICompatibleHTTPTransport.execute(request, settings)

        assert {:ok, raw_request} = Task.await(request_task)
        assert raw_request =~ ~r/\r\nhost: \[::1\]:[0-9]+\r\n/i

      {:error, reason} ->
        assert reason in [:eafnosupport, :eaddrnotavail]
    end
  end

  test "classifies pre-send failures and rejects forged inputs" do
    {:ok, listener} = listen()
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    settings = settings("http://127.0.0.1:#{port}/v1")
    prompt = prompt()
    {:ok, request} = OpenAICompatibleRequest.encode(prompt, settings)

    assert OpenAICompatibleHTTPTransport.execute(request, settings) ==
             {:error, :not_sent, :unavailable}

    forged = %{request | url: "http://example.invalid/private"}

    assert OpenAICompatibleHTTPTransport.execute(forged, settings) ==
             {:error, :invalid_response}

    assert OpenAICompatibleHTTPTransport.execute(nil, settings) ==
             {:error, :invalid_response}
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

    {settings("http://#{endpoint_host}:#{port}/v1"), task}
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

    {settings("http://127.0.0.1:#{port}/v1"), task}
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
    headers = [
      "HTTP/1.1 #{status} Test\r\n",
      if(content_type, do: "content-type: #{content_type}\r\n", else: []),
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n"
    ]

    with :ok <- :gen_tcp.send(socket, headers), do: send_chunks(socket, body, chunk_size)
  end

  defp send_chunks(socket, body, :all), do: :gen_tcp.send(socket, body)
  defp send_chunks(_socket, <<>>, _chunk_size), do: :ok

  defp send_chunks(socket, body, chunk_size) do
    size = min(byte_size(body), chunk_size)
    <<chunk::binary-size(size), remaining::binary>> = body

    with :ok <- :gen_tcp.send(socket, chunk), do: send_chunks(socket, remaining, chunk_size)
  end

  defp success_body(content) do
    %{"choices" => [%{"message" => %{"content" => content, "role" => "assistant"}}]}
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp settings(base_url) do
    %ProviderSettings{
      provider: :openai_compatible,
      base_url: base_url,
      model: "example-model",
      api_key: @api_key,
      timeout_ms: 5_000,
      max_output_tokens: 300
    }
  end

  defp prompt do
    %PromptRequest{
      system_instruction: PromptAssembler.system_instruction(),
      persona: %{
        "display_name" => "Observer",
        "instructions" => "Speak briefly from supplied facts only."
      },
      confirmed_facts: %{
        "current_state" => %{"state" => "healthy"},
        "details" => %{"attempt" => 2},
        "event_type" => "observation.recovered",
        "group" => "recovery",
        "occurred_at" => "2026-08-05T12:00:00.000000Z",
        "occurred_at_timezone" => "Etc/UTC",
        "previous_state" => %{"state" => "failed"},
        "severity" => "info",
        "subject" => "example-target"
      },
      creative_context: %{"conversation_kind" => "recovery", "mood" => "relieved"},
      conversation: [%{"content" => "The latest run completed.", "speaker" => "Caretaker"}]
    }
  end
end

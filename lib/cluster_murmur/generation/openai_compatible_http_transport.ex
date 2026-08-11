defmodule ClusterMurmur.Generation.OpenAICompatibleHTTPTransport do
  @moduledoc """
  Executes one fixed OpenAI-compatible request through a bounded HTTP connection.

  Each call opens one passive HTTP/1 connection, sends one independently
  revalidated generation request, incrementally bounds the response, and closes
  the connection. Redirects, retries, proxies, pooling, and caller-selected
  HTTP values are not exposed.
  """

  alias ClusterMurmur.Generation.{
    OpenAICompatibleRequest,
    OpenAICompatibleResponse,
    ProviderSettings
  }

  @max_response_header_bytes 16 * 1_024
  @max_response_wire_bytes 96 * 1_024
  @receive_buffer_bytes 4 * 1_024

  @type result ::
          {:ok, OpenAICompatibleResponse.t()}
          | {:error, :not_sent, :timeout | :unavailable}
          | {:error, :invalid_response}
          | {:error, :outcome_unknown}

  @doc "Executes one exact application-assembled generation request."
  @spec execute(term(), term()) :: result()
  def execute(%OpenAICompatibleRequest{} = request, %ProviderSettings{} = settings) do
    with :ok <- OpenAICompatibleRequest.validate_for_transport(request, settings),
         {:ok, uri} <- URI.new(request.url) do
      execute_request(request, uri)
    else
      _invalid -> {:error, :invalid_response}
    end
  rescue
    _error -> {:error, :invalid_response}
  catch
    _kind, _reason -> {:error, :invalid_response}
  end

  def execute(_request, _settings), do: {:error, :invalid_response}

  defp execute_request(request, uri) do
    deadline = monotonic_milliseconds() + request.overall_timeout_ms
    scheme = connection_scheme(uri)

    case safe_connect(uri, request, deadline) do
      {:ok, conn} -> send_request(conn, request, uri, scheme, deadline)
      {:error, reason} -> classify_connect_error(reason)
    end
  end

  defp connection_scheme(%URI{scheme: "https"}), do: :https
  defp connection_scheme(%URI{scheme: "http"}), do: :http

  defp safe_connect(uri, request, deadline) do
    connect(uri, request, deadline)
  rescue
    _error -> {:error, :connect_failed}
  catch
    _kind, _reason -> {:error, :connect_failed}
  end

  defp connect(uri, request, deadline) do
    scheme = connection_scheme(uri)
    address = connection_address(scheme, uri.host)
    timeout = min(request.connect_timeout_ms, remaining(deadline))

    options = [
      hostname: uri.host,
      mode: :passive,
      protocols: [:http1],
      max_header_list_size: @max_response_header_bytes,
      transport_opts: transport_options(scheme, address, timeout)
    ]

    Mint.HTTP.connect(scheme, address, uri.port, options)
  end

  defp connection_address(:http, "localhost"), do: {127, 0, 0, 1}

  defp connection_address(_scheme, host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> address
      {:error, _reason} -> host
    end
  end

  defp transport_options(:http, address, timeout),
    do:
      [
        timeout: timeout,
        buffer: @receive_buffer_bytes,
        send_timeout: timeout,
        send_timeout_close: true
      ] ++
        address_family_options(address)

  defp transport_options(:https, address, timeout) do
    [
      timeout: timeout,
      buffer: @receive_buffer_bytes,
      send_timeout: timeout,
      send_timeout_close: true,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ] ++ address_family_options(address)
  end

  defp address_family_options(address) when is_tuple(address) and tuple_size(address) == 8,
    do: [inet6: true, inet4: false]

  defp address_family_options(address) when is_tuple(address) and tuple_size(address) == 4,
    do: [inet6: false, inet4: true]

  defp address_family_options(_hostname), do: [inet6: false, inet4: true]

  defp send_request(conn, request, uri, scheme, deadline) do
    body = request.json |> :json.encode() |> IO.iodata_to_binary()
    headers = request_headers(request.headers, uri)

    case safe_configure_socket(conn, scheme, deadline) do
      :ok ->
        dispatch_request(conn, request, uri, scheme, deadline, headers, body)

      {:error, :timeout} ->
        close_with(conn, scheme, deadline, {:error, :not_sent, :timeout})

      {:error, :unavailable} ->
        close_with(conn, scheme, deadline, {:error, :not_sent, :unavailable})
    end
  rescue
    _error -> close_with(conn, scheme, deadline, {:error, :invalid_response})
  catch
    _kind, _reason -> close_with(conn, scheme, deadline, {:error, :invalid_response})
  end

  defp safe_configure_socket(conn, scheme, deadline) do
    socket = Mint.HTTP.get_socket(conn)

    with :ok <- set_socket_options(scheme, socket, buffer: @receive_buffer_bytes),
         {:ok, actual} <- get_socket_options(scheme, socket, [:buffer]),
         @receive_buffer_bytes <- Keyword.get(actual, :buffer),
         :ok <- configure_send_timeout(scheme, socket, deadline) do
      :ok
    else
      {:error, :timeout} = error -> error
      _failure -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp configure_send_timeout(scheme, socket, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        set_socket_options(scheme, socket,
          send_timeout: timeout,
          send_timeout_close: true
        )
    end
  end

  defp set_socket_options(:http, socket, options), do: :inet.setopts(socket, options)
  defp set_socket_options(:https, socket, options), do: :ssl.setopts(socket, options)
  defp get_socket_options(:http, socket, options), do: :inet.getopts(socket, options)
  defp get_socket_options(:https, socket, options), do: :ssl.getopts(socket, options)

  defp dispatch_request(conn, request, uri, scheme, deadline, headers, body) do
    case Mint.HTTP.request(conn, "POST", uri.path, headers, body) do
      {:ok, conn, reference} -> receive_response(conn, reference, request, scheme, deadline)
      {:error, conn, _reason} -> close_with(conn, scheme, deadline, {:error, :outcome_unknown})
    end
  rescue
    _error -> close_with(conn, scheme, deadline, {:error, :outcome_unknown})
  catch
    _kind, _reason -> close_with(conn, scheme, deadline, {:error, :outcome_unknown})
  end

  defp request_headers(headers, %URI{host: host, port: port}) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 8 -> [{"host", "[#{host}]:#{port}"} | headers]
      _not_ipv6_literal -> headers
    end
  end

  defp receive_response(conn, reference, request, scheme, deadline) do
    state = %{
      body: [],
      body_bytes: 0,
      headers: nil,
      informational: false,
      status: nil,
      wire_bytes: 0
    }

    receive_response(conn, reference, request, scheme, deadline, state)
  end

  defp receive_response(conn, reference, request, scheme, deadline, state) do
    timeout = min(request.receive_timeout_ms, remaining(deadline))

    if timeout == 0 do
      close_with(conn, scheme, deadline, {:error, :outcome_unknown})
    else
      socket = Mint.HTTP.get_socket(conn)

      case safe_receive(scheme, socket, timeout) do
        {:ok, data} ->
          continue_transport_data(
            conn,
            reference,
            request,
            scheme,
            socket,
            deadline,
            state,
            data
          )

        {:error, :closed} ->
          continue_stream_message(
            conn,
            reference,
            request,
            scheme,
            deadline,
            state,
            transport_closed_message(scheme, socket)
          )

        {:error, _reason} ->
          close_with(conn, scheme, deadline, {:error, :outcome_unknown})
      end
    end
  rescue
    _error -> close_with(conn, scheme, deadline, {:error, :outcome_unknown})
  catch
    _kind, _reason -> close_with(conn, scheme, deadline, {:error, :outcome_unknown})
  end

  defp safe_receive(:http, socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)
  defp safe_receive(:https, socket, timeout), do: :ssl.recv(socket, 0, timeout)

  defp continue_transport_data(
         conn,
         reference,
         request,
         scheme,
         socket,
         deadline,
         state,
         data
       )
       when is_binary(data) do
    wire_bytes = state.wire_bytes + byte_size(data)

    if wire_bytes <= @max_response_wire_bytes do
      continue_stream_message(
        conn,
        reference,
        request,
        scheme,
        deadline,
        %{state | wire_bytes: wire_bytes},
        transport_data_message(scheme, socket, data)
      )
    else
      close_with(conn, scheme, deadline, {:error, :invalid_response})
    end
  end

  defp continue_stream_message(
         conn,
         reference,
         request,
         scheme,
         deadline,
         state,
         message
       ) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        continue_responses(conn, reference, request, scheme, deadline, state, responses)

      {:error, conn, reason, responses} ->
        case reduce_responses(state, responses, reference, request.max_response_bytes) do
          {:done, result} ->
            close_with(conn, scheme, deadline, result)

          _unfinished when is_struct(reason, Mint.HTTPError) ->
            close_with(conn, scheme, deadline, {:error, :invalid_response})

          _unfinished ->
            close_with(conn, scheme, deadline, {:error, :outcome_unknown})
        end

      :unknown ->
        close_with(conn, scheme, deadline, {:error, :invalid_response})
    end
  end

  defp transport_data_message(:http, socket, data), do: {:tcp, socket, data}
  defp transport_data_message(:https, socket, data), do: {:ssl, socket, data}
  defp transport_closed_message(:http, socket), do: {:tcp_closed, socket}
  defp transport_closed_message(:https, socket), do: {:ssl_closed, socket}

  defp continue_responses(conn, reference, request, scheme, deadline, state, responses) do
    case reduce_responses(state, responses, reference, request.max_response_bytes) do
      {:continue, state} -> receive_response(conn, reference, request, scheme, deadline, state)
      {:done, result} -> close_with(conn, scheme, deadline, result)
    end
  end

  defp reduce_responses(state, responses, reference, max_response_bytes) do
    Enum.reduce_while(responses, {:continue, state}, fn response, {:continue, current} ->
      case reduce_response(current, response, reference, max_response_bytes) do
        {:continue, next} -> {:cont, {:continue, next}}
        {:done, result} -> {:halt, {:done, result}}
      end
    end)
  end

  defp reduce_response(state, {:status, reference, status}, reference, _max)
       when status in 100..199 and is_nil(state.status) do
    {:continue, %{state | informational: true}}
  end

  defp reduce_response(state, {:status, reference, status}, reference, _max)
       when status in 200..599 and is_nil(state.status) and not state.informational do
    {:continue, %{state | status: status}}
  end

  defp reduce_response(state, {:headers, reference, _headers}, reference, _max)
       when state.informational do
    {:continue, %{state | informational: false}}
  end

  defp reduce_response(state, {:headers, reference, headers}, reference, _max)
       when is_integer(state.status) and is_nil(state.headers) and is_list(headers) do
    {:continue, %{state | headers: headers}}
  end

  defp reduce_response(state, {:headers, reference, _trailers}, reference, _max)
       when is_list(state.headers),
       do: {:continue, state}

  defp reduce_response(state, {:data, reference, data}, reference, max)
       when is_list(state.headers) and is_binary(data) do
    next_bytes = state.body_bytes + byte_size(data)

    if next_bytes <= max,
      do: {:continue, %{state | body: [data | state.body], body_bytes: next_bytes}},
      else: {:done, {:error, :invalid_response}}
  end

  defp reduce_response(state, {:done, reference}, reference, _max)
       when is_integer(state.status) and is_list(state.headers) do
    {:done, decode_response(state)}
  end

  defp reduce_response(_state, {:error, reference, _reason}, reference, _max),
    do: {:done, {:error, :outcome_unknown}}

  defp reduce_response(_state, _response, _reference, _max),
    do: {:done, {:error, :invalid_response}}

  defp decode_response(state) do
    body = state.body |> Enum.reverse() |> IO.iodata_to_binary()

    with :ok <- validate_response_media_type(state.status, state.headers) do
      {:ok,
       %OpenAICompatibleResponse{
         status: state.status,
         body: body
       }}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp validate_response_media_type(200, headers), do: require_json_media_type(headers)
  defp validate_response_media_type(_status, _headers), do: :ok

  defp require_json_media_type(headers) do
    case content_types(headers) do
      [value] -> validate_json_media_type(value)
      _missing_or_multiple -> {:error, :invalid_response}
    end
  end

  defp content_types(headers) do
    for {name, value} <- headers,
        is_binary(name),
        is_binary(value),
        String.valid?(name),
        String.downcase(name) == "content-type",
        do: value
  end

  defp validate_json_media_type(value) when is_binary(value) do
    if String.valid?(value),
      do: validate_normalized_json_media_type(value),
      else: {:error, :invalid_response}
  end

  defp validate_json_media_type(_value), do: {:error, :invalid_response}

  defp validate_normalized_json_media_type(value) do
    media_type =
      value
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    if media_type == "application/json", do: :ok, else: {:error, :invalid_response}
  end

  defp classify_connect_error(%Mint.TransportError{reason: :timeout}),
    do: {:error, :not_sent, :timeout}

  defp classify_connect_error(_reason), do: {:error, :not_sent, :unavailable}

  defp close_with(conn, scheme, deadline, result) do
    socket = Mint.HTTP.get_socket(conn)
    _closed = close_socket(scheme, socket, remaining(deadline))
    result
  rescue
    _error -> result
  catch
    _kind, _reason -> result
  end

  defp close_socket(:http, socket, _timeout), do: :gen_tcp.close(socket)
  defp close_socket(:https, socket, timeout), do: :ssl.close(socket, timeout)

  defp remaining(deadline), do: max(deadline - monotonic_milliseconds(), 0)
  defp monotonic_milliseconds, do: System.monotonic_time(:millisecond)
end

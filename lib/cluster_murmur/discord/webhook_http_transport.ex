defmodule ClusterMurmur.Discord.WebhookHTTPTransport do
  @moduledoc """
  Executes one fixed Discord incoming-webhook request over bounded HTTPS.

  Each call revalidates the complete request against startup-captured settings,
  opens one passive HTTP/1 connection to Discord, sends once, incrementally
  bounds the response, and closes the connection. It exposes no redirects,
  retries, proxies, pooling, or caller-selected HTTP authority.
  """

  alias ClusterMurmur.Discord.{
    WebhookHTTPResponseAccumulator,
    WebhookRequest,
    WebhookResponse,
    WebhookSettings
  }

  alias ClusterMurmur.Runtime.OperationalTelemetry

  @max_response_header_bytes 16 * 1_024
  @max_response_wire_bytes 96 * 1_024
  @receive_buffer_bytes 4 * 1_024
  @discord_host "discord.com"

  @type result ::
          {:ok, WebhookResponse.t()}
          | {:error, :not_sent, :invalid_request | :timeout | :unavailable}
          | {:error, :outcome_unknown}

  @doc "Executes one exact application-assembled Discord webhook request."
  @spec execute(term(), term()) :: result()
  def execute(request, settings) do
    started_at = System.monotonic_time()

    request
    |> do_execute(settings)
    |> OperationalTelemetry.external_request(:discord_webhook, started_at)
  end

  defp do_execute(%WebhookRequest{} = request, %WebhookSettings{} = settings) do
    with :ok <- WebhookRequest.validate_for_transport(request, settings),
         {:ok, uri} <- URI.new(request.url),
         true <- fixed_discord_uri?(uri) do
      execute_request(request, uri)
    else
      _invalid -> {:error, :not_sent, :invalid_request}
    end
  rescue
    _error -> {:error, :not_sent, :invalid_request}
  catch
    _kind, _reason -> {:error, :not_sent, :invalid_request}
  end

  defp do_execute(_request, _settings), do: {:error, :not_sent, :invalid_request}

  defp fixed_discord_uri?(%URI{scheme: "https", host: host, port: 443})
       when is_binary(host),
       do: String.downcase(host) == @discord_host

  defp fixed_discord_uri?(_uri), do: false

  defp execute_request(request, uri) do
    deadline = monotonic_milliseconds() + request.overall_timeout_ms

    case safe_connect(uri, request, deadline) do
      {:ok, conn} -> send_request(conn, request, uri, deadline)
      {:error, reason} -> classify_connect_error(reason)
    end
  end

  defp safe_connect(uri, request, deadline) do
    case remaining(deadline) do
      0 -> {:error, :deadline_expired}
      _remaining -> connect(uri, request, deadline)
    end
  rescue
    _error -> {:error, :connect_failed}
  catch
    _kind, _reason -> {:error, :connect_failed}
  end

  defp connect(uri, request, deadline) do
    cacerts = :public_key.cacerts_get()
    timeout = min(request.connect_timeout_ms, remaining(deadline))

    if timeout == 0 do
      {:error, :deadline_expired}
    else
      options = [
        hostname: @discord_host,
        mode: :passive,
        protocols: [:http1],
        max_header_list_size: @max_response_header_bytes,
        transport_opts: [
          timeout: timeout,
          buffer: @receive_buffer_bytes,
          send_timeout: timeout,
          send_timeout_close: true,
          verify: :verify_peer,
          cacerts: cacerts,
          versions: [:"tlsv1.3", :"tlsv1.2"],
          inet6: false,
          inet4: true
        ]
      ]

      Mint.HTTP.connect(:https, @discord_host, uri.port, options)
    end
  end

  defp send_request(conn, request, uri, deadline) do
    body = request.json |> :json.encode() |> IO.iodata_to_binary()
    target = uri.path <> "?" <> URI.encode_query(request.query)

    case safe_configure_socket(conn, deadline) do
      :ok -> dispatch_request(conn, request, target, deadline, body)
      {:error, reason} -> close_with(conn, deadline, {:error, :not_sent, reason})
    end
  rescue
    _error -> close_with(conn, deadline, {:error, :not_sent, :invalid_request})
  catch
    _kind, _reason -> close_with(conn, deadline, {:error, :not_sent, :invalid_request})
  end

  defp safe_configure_socket(conn, deadline) do
    socket = Mint.HTTP.get_socket(conn)

    with :ok <- :ssl.setopts(socket, buffer: @receive_buffer_bytes),
         {:ok, actual} <- :ssl.getopts(socket, [:buffer]),
         @receive_buffer_bytes <- Keyword.get(actual, :buffer),
         :ok <- configure_send_timeout(socket, deadline) do
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

  defp configure_send_timeout(socket, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        :ssl.setopts(socket, send_timeout: timeout, send_timeout_close: true)
    end
  end

  defp dispatch_request(conn, request, target, deadline, body) do
    case Mint.HTTP.request(conn, "POST", target, request.headers, body) do
      {:ok, conn, reference} -> receive_response(conn, reference, request, deadline)
      {:error, conn, _reason} -> close_with(conn, deadline, {:error, :outcome_unknown})
    end
  rescue
    _error -> close_with(conn, deadline, {:error, :outcome_unknown})
  catch
    _kind, _reason -> close_with(conn, deadline, {:error, :outcome_unknown})
  end

  defp receive_response(conn, reference, request, deadline) do
    state = %WebhookHTTPResponseAccumulator{}
    receive_response(conn, reference, request, deadline, state, 0)
  end

  defp receive_response(conn, reference, request, deadline, state, wire_bytes) do
    timeout = min(request.receive_timeout_ms, remaining(deadline))

    if timeout == 0 do
      close_with(conn, deadline, {:error, :outcome_unknown})
    else
      socket = Mint.HTTP.get_socket(conn)

      case safe_receive(socket, timeout) do
        {:ok, data} ->
          continue_transport_data(
            conn,
            reference,
            request,
            socket,
            deadline,
            state,
            wire_bytes,
            data
          )

        {:error, :closed} ->
          continue_stream_message(
            conn,
            reference,
            request,
            deadline,
            state,
            wire_bytes,
            {:ssl_closed, socket}
          )

        {:error, _reason} ->
          close_with(conn, deadline, {:error, :outcome_unknown})
      end
    end
  rescue
    _error -> close_with(conn, deadline, {:error, :outcome_unknown})
  catch
    _kind, _reason -> close_with(conn, deadline, {:error, :outcome_unknown})
  end

  defp safe_receive(socket, timeout), do: :ssl.recv(socket, 0, timeout)

  defp continue_transport_data(
         conn,
         reference,
         request,
         socket,
         deadline,
         state,
         wire_bytes,
         data
       )
       when is_binary(data) do
    next_wire_bytes = wire_bytes + byte_size(data)

    if next_wire_bytes <= @max_response_wire_bytes do
      continue_stream_message(
        conn,
        reference,
        request,
        deadline,
        state,
        next_wire_bytes,
        {:ssl, socket, data}
      )
    else
      close_with(conn, deadline, {:error, :outcome_unknown})
    end
  end

  defp continue_stream_message(
         conn,
         reference,
         request,
         deadline,
         state,
         wire_bytes,
         message
       ) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        continue_responses(conn, reference, request, deadline, state, wire_bytes, responses)

      {:error, conn, _reason, responses} ->
        case WebhookHTTPResponseAccumulator.reduce(
               state,
               responses,
               reference,
               request.max_response_bytes
             ) do
          {:done, result} -> close_with(conn, deadline, result)
          {:continue, _unfinished} -> close_with(conn, deadline, {:error, :outcome_unknown})
        end

      :unknown ->
        close_with(conn, deadline, {:error, :outcome_unknown})
    end
  end

  defp continue_responses(
         conn,
         reference,
         request,
         deadline,
         state,
         wire_bytes,
         responses
       ) do
    case WebhookHTTPResponseAccumulator.reduce(
           state,
           responses,
           reference,
           request.max_response_bytes
         ) do
      {:continue, state} ->
        receive_response(conn, reference, request, deadline, state, wire_bytes)

      {:done, result} ->
        close_with(conn, deadline, result)
    end
  end

  defp classify_connect_error(:deadline_expired), do: {:error, :not_sent, :timeout}

  defp classify_connect_error(%Mint.TransportError{reason: :timeout}),
    do: {:error, :not_sent, :timeout}

  defp classify_connect_error(_reason), do: {:error, :not_sent, :unavailable}

  defp close_with(conn, deadline, result) do
    socket = Mint.HTTP.get_socket(conn)
    _closed = :ssl.close(socket, remaining(deadline))
    result
  rescue
    _error -> result
  catch
    _kind, _reason -> result
  end

  defp remaining(deadline), do: max(deadline - monotonic_milliseconds(), 0)
  defp monotonic_milliseconds, do: System.monotonic_time(:millisecond)
end

defmodule ClusterMurmur.Runtime.ExternalIngestionServer do
  @moduledoc """
  Serves one authenticated, bounded, loopback-only event ingestion route.

  The server accepts one HTTP/1.1 request per connection. It fixes the listener
  address, route, method, media type, timeouts, request bounds, concurrency, and
  rate. Only a fully authenticated and decoded envelope reaches the atomic
  external event commit store.
  """

  use GenServer

  require Logger

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Ingestion.{BearerAuthentication, EventEnvelopeDecoder, HTTPSettings}

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventRecord,
    ExternalEventCommitStore
  }

  @accept_timeout_ms 100
  @request_timeout_ms 1_000
  @max_header_bytes 8 * 1_024
  @max_body_bytes 64 * 1_024
  @max_connections 16
  @rate_window_ms 1_000
  @max_requests_per_window 20

  defmodule Options do
    @moduledoc false

    @derive {Inspect, only: [:settings]}
    @enforce_keys [:settings, :configuration, :clock, :commit]
    defstruct [:settings, :configuration, :clock, :commit]

    @type t :: %__MODULE__{
            settings: ClusterMurmur.Ingestion.HTTPSettings.t(),
            configuration: ClusterMurmur.Config.ExternalIngestion.t(),
            clock: module(),
            commit: (term(), term(), term() -> term())
          }
  end

  @option_keys [:__struct__, :settings, :configuration, :clock, :commit]
  @option_key_count length(@option_keys)

  @type state :: %{
          listener: port(),
          options: Options.t(),
          workers: %{reference() => pid()},
          rate_started_at: integer(),
          rate_count: non_neg_integer(),
          rate_limited_logged: boolean()
        }

  @doc "Starts the fixed loopback external event ingestion server."
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    case validate_options(options) do
      :ok -> GenServer.start_link(__MODULE__, options)
      {:error, :invalid_external_ingestion_server} = error -> error
    end
  end

  def start_link(_options), do: {:error, :invalid_external_ingestion_server}

  @doc false
  @spec validate_options(term()) :: :ok | {:error, :invalid_external_ingestion_server}
  def validate_options(%Options{} = options) do
    if exact_options?(options) and HTTPSettings.validate(options.settings) == :ok and
         ExternalIngestion.validate(options.configuration) == :ok and
         map_size(options.configuration.sources) > 0 and is_atom(options.clock) and
         Code.ensure_loaded?(options.clock) and function_exported?(options.clock, :utc_now, 0) and
         is_function(options.commit, 3) do
      :ok
    else
      {:error, :invalid_external_ingestion_server}
    end
  rescue
    _error -> {:error, :invalid_external_ingestion_server}
  catch
    _kind, _reason -> {:error, :invalid_external_ingestion_server}
  end

  def validate_options(_options), do: {:error, :invalid_external_ingestion_server}

  @impl true
  def init(%Options{} = options) do
    socket_options = [
      :binary,
      active: false,
      packet: :raw,
      reuseaddr: true,
      nodelay: true,
      backlog: @max_connections,
      recbuf: @max_header_bytes + @max_body_bytes,
      send_timeout: @request_timeout_ms,
      send_timeout_close: true,
      ip: {127, 0, 0, 1}
    ]

    case :gen_tcp.listen(options.settings.port, socket_options) do
      {:ok, listener} ->
        send(self(), :accept)

        {:ok,
         %{
           listener: listener,
           options: options,
           workers: %{},
           rate_started_at: monotonic_milliseconds(),
           rate_count: 0,
           rate_limited_logged: false
         }}

      {:error, _reason} ->
        {:stop, :invalid_external_ingestion_server}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listener, @accept_timeout_ms) do
      {:ok, socket} ->
        send(self(), :accept)
        {:noreply, admit(socket, refresh_rate(state))}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, _reason} ->
        {:stop, :invalid_external_ingestion_server, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | workers: Map.delete(state.workers, monitor)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    Enum.each(state.workers, fn {_monitor, worker} -> :erlang.exit(worker, :kill) end)
    :ok
  end

  defp admit(socket, state)
       when map_size(state.workers) < @max_connections and
              state.rate_count < @max_requests_per_window do
    {worker, monitor} = spawn_monitor(fn -> await_socket() end)

    case :gen_tcp.controlling_process(socket, worker) do
      :ok ->
        send(worker, {:serve, socket, state.options})

        %{
          state
          | workers: Map.put(state.workers, monitor, worker),
            rate_count: state.rate_count + 1
        }

      {:error, _reason} ->
        :erlang.exit(worker, :kill)
        :erlang.demonitor(monitor, [:flush])
        :gen_tcp.close(socket)
        state
    end
  end

  defp admit(socket, state) do
    :gen_tcp.send(socket, response(429))
    :gen_tcp.close(socket)

    if state.rate_limited_logged do
      state
    else
      log_outcome(:rejected, nil, nil, :rate_limited)
      %{state | rate_limited_logged: true}
    end
  end

  defp await_socket do
    receive do
      {:serve, socket, options} ->
        try do
          serve(socket, options)
        after
          :gen_tcp.close(socket)
        end
    after
      @request_timeout_ms -> :ok
    end
  end

  defp serve(socket, options) do
    deadline = monotonic_milliseconds() + @request_timeout_ms

    case receive_headers(socket, <<>>, deadline) do
      {:ok, head} -> serve_head(socket, head, options, deadline)
      {:error, status} -> reject_request(socket, status)
    end
  rescue
    _error -> internal_failure(socket)
  catch
    _kind, _reason -> internal_failure(socket)
  end

  defp serve_head(socket, head, options, deadline) do
    with {:ok, authorization, content_length} <- parse_head(head),
         :ok <- BearerAuthentication.authorize(authorization, options.settings.token_digest),
         {:ok, body} <- receive_body(socket, content_length, deadline),
         :ok <- reject_buffered_input(socket) do
      process_body(socket, body, options)
    else
      {:error, :unauthorized} -> reject_request(socket, 401)
      {:error, status} when is_integer(status) -> reject_request(socket, status)
      _failure -> reject_request(socket, 400)
    end
  end

  defp process_body(socket, body, options) do
    with {:ok, envelope} <- EventEnvelopeDecoder.decode(body, options.configuration),
         %DateTime{} = accepted_at <- options.clock.utc_now(),
         :ok <- DateTimeValidator.validate_storage_utc(accepted_at) do
      options.commit.(envelope, options.configuration, accepted_at)
      |> commit_response(socket)
    else
      _failure ->
        log_outcome(:invalid, nil, nil)
        :gen_tcp.send(socket, response(400))
    end
  end

  defp commit_response(
         {:ok,
          %ExternalEventCommitStore.Result{
            event: %EventRecord{id: event_id},
            dispatch: %EventDispatchReceipt{event_id: event_id},
            duplicate?: duplicate?
          }},
         socket
       )
       when is_binary(event_id) and is_boolean(duplicate?) do
    log_outcome(:accepted, event_id, duplicate?)
    :gen_tcp.send(socket, response(202))
  end

  defp commit_response({:error, :external_event_conflict}, socket) do
    log_outcome(:conflict, nil, nil)
    :gen_tcp.send(socket, response(409))
  end

  defp commit_response({:error, :invalid_external_event_commit}, socket) do
    log_outcome(:invalid, nil, nil)
    :gen_tcp.send(socket, response(400))
  end

  defp commit_response({:error, :storage_unavailable}, socket) do
    log_outcome(:unavailable, nil, nil)
    :gen_tcp.send(socket, response(503))
  end

  defp commit_response(_unexpected, socket) do
    log_outcome(:unavailable, nil, nil)
    :gen_tcp.send(socket, response(503))
  end

  defp receive_headers(socket, headers, deadline) when byte_size(headers) <= @max_header_bytes do
    case :binary.match(headers, "\r\n\r\n") do
      {position, 4} when position + 4 == byte_size(headers) ->
        {:ok, binary_part(headers, 0, position)}

      {_position, 4} ->
        {:error, 400}

      :nomatch ->
        receive_header_byte(socket, headers, deadline)
    end
  end

  defp receive_headers(_socket, _headers, _deadline), do: {:error, 431}

  defp receive_header_byte(socket, headers, deadline) do
    remaining_ms = deadline - monotonic_milliseconds()

    if remaining_ms > 0 and byte_size(headers) < @max_header_bytes do
      case :gen_tcp.recv(socket, 1, remaining_ms) do
        {:ok, byte} -> receive_headers(socket, headers <> byte, deadline)
        {:error, :timeout} -> {:error, 408}
        _failure -> {:error, 400}
      end
    else
      {:error, if(byte_size(headers) >= @max_header_bytes, do: 431, else: 408)}
    end
  end

  defp parse_head(head) when is_binary(head) do
    with true <- String.valid?(head),
         [request_line | header_lines] <- :binary.split(head, "\r\n", [:global]),
         :ok <- validate_request_line(request_line),
         {:ok, headers} <- parse_headers(header_lines),
         {:ok, authorization} <- authorization_header(headers),
         {:ok, host} <- required_header(headers, "host"),
         true <- byte_size(host) > 0,
         {:ok, content_type} <- required_header(headers, "content-type"),
         :ok <- validate_content_type(content_type),
         false <- Map.has_key?(headers, "transfer-encoding"),
         {:ok, encoded_length} <- required_header(headers, "content-length"),
         {:ok, content_length} <- parse_content_length(encoded_length) do
      {:ok, authorization, content_length}
    else
      {:error, status} -> {:error, status}
      _failure -> {:error, 400}
    end
  end

  defp parse_head(_head), do: {:error, 400}

  defp validate_request_line("POST /v1/events HTTP/1.1"), do: :ok
  defp validate_request_line(_request_line), do: {:error, 404}

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, headers} ->
      case parse_header(line) do
        {:ok, name, value} ->
          if Map.has_key?(headers, name),
            do: {:halt, {:error, 400}},
            else: {:cont, {:ok, Map.put(headers, name, value)}}

        {:error, 400} = error ->
          {:halt, error}
      end
    end)
  end

  defp parse_header(line) do
    case :binary.split(line, ":") do
      [name, value] ->
        normalized_name = String.downcase(name)
        normalized_value = String.trim(value)

        if valid_header_name?(normalized_name) and byte_size(normalized_value) > 0,
          do: {:ok, normalized_name, normalized_value},
          else: {:error, 400}

      _invalid ->
        {:error, 400}
    end
  end

  defp valid_header_name?(name) when byte_size(name) > 0 do
    name
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?a..?z or byte in ?0..?9 or byte == ?- end)
  end

  defp valid_header_name?(_name), do: false

  defp required_header(headers, name) do
    case Map.fetch(headers, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, 400}
    end
  end

  defp authorization_header(headers) do
    case Map.fetch(headers, "authorization") do
      {:ok, value} -> {:ok, value}
      :error -> {:error, 401}
    end
  end

  defp validate_content_type(value) do
    normalized = value |> String.downcase() |> String.split(";") |> Enum.map(&String.trim/1)

    if normalized in [["application/json"], ["application/json", "charset=utf-8"]],
      do: :ok,
      else: {:error, 415}
  end

  defp parse_content_length(value) do
    cond do
      byte_size(value) == 0 or not decimal_digits?(value) ->
        {:error, 400}

      byte_size(value) > 5 ->
        {:error, 413}

      true ->
        case Integer.parse(value) do
          {length, ""} when length in 0..@max_body_bytes -> {:ok, length}
          {length, ""} when length > @max_body_bytes -> {:error, 413}
        end
    end
  end

  defp decimal_digits?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))
  end

  defp receive_body(_socket, 0, _deadline), do: {:ok, <<>>}

  defp receive_body(socket, content_length, deadline) do
    remaining_ms = deadline - monotonic_milliseconds()

    if remaining_ms > 0 do
      case :gen_tcp.recv(socket, content_length, remaining_ms) do
        {:ok, body} when byte_size(body) == content_length -> {:ok, body}
        _failure -> {:error, 408}
      end
    else
      {:error, 408}
    end
  end

  defp reject_buffered_input(socket) do
    case :gen_tcp.recv(socket, 1, 0) do
      {:error, :timeout} -> :ok
      {:error, :closed} -> :ok
      _extra_or_failure -> {:error, 400}
    end
  end

  defp refresh_rate(state) do
    now = monotonic_milliseconds()

    if now - state.rate_started_at >= @rate_window_ms,
      do: %{state | rate_started_at: now, rate_count: 0, rate_limited_logged: false},
      else: state
  end

  defp reject_request(socket, status) do
    error_class =
      case status do
        401 -> :authentication_failed
        408 -> :timeout
        429 -> :rate_limited
        _other -> :invalid_request
      end

    log_outcome(:rejected, nil, nil, error_class)
    :gen_tcp.send(socket, response(status))
  end

  defp internal_failure(socket) do
    log_outcome(:unavailable, nil, nil, :unavailable)
    :gen_tcp.send(socket, response(500))
  end

  defp log_outcome(outcome, event_id, duplicate?, error_class \\ nil) do
    metadata = [component: :external_ingestion, outcome: outcome, error_class: error_class]

    metadata =
      if is_binary(event_id), do: Keyword.put(metadata, :event_id, event_id), else: metadata

    metadata =
      if is_boolean(duplicate?), do: Keyword.put(metadata, :duplicate, duplicate?), else: metadata

    level = if outcome == :accepted, do: :info, else: :warning
    Logger.log(level, "external ingestion request completed", metadata)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp response(202), do: http_response(202, "Accepted", "accepted\n", [])
  defp response(400), do: http_response(400, "Bad Request", "invalid\n", [])

  defp response(401),
    do: http_response(401, "Unauthorized", "unauthorized\n", [{"www-authenticate", "Bearer"}])

  defp response(404), do: http_response(404, "Not Found", "not found\n", [])
  defp response(408), do: http_response(408, "Request Timeout", "timeout\n", [])
  defp response(409), do: http_response(409, "Conflict", "conflict\n", [])
  defp response(413), do: http_response(413, "Content Too Large", "too large\n", [])
  defp response(415), do: http_response(415, "Unsupported Media Type", "unsupported\n", [])
  defp response(429), do: http_response(429, "Too Many Requests", "rate limited\n", [])

  defp response(431),
    do: http_response(431, "Request Header Fields Too Large", "too large\n", [])

  defp response(500), do: http_response(500, "Internal Server Error", "unavailable\n", [])
  defp response(503), do: http_response(503, "Service Unavailable", "unavailable\n", [])

  defp http_response(status, reason, body, additional_headers) do
    headers = [
      {"content-type", "text/plain; charset=utf-8"},
      {"content-length", Integer.to_string(byte_size(body))},
      {"cache-control", "no-store"},
      {"connection", "close"}
    ]

    encoded_headers =
      additional_headers
      |> Kernel.++(headers)
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    "HTTP/1.1 #{status} #{reason}\r\n" <> encoded_headers <> "\r\n" <> body
  end

  defp exact_options?(options) do
    map_size(options) == @option_key_count and
      Enum.all?(@option_keys, &Map.has_key?(options, &1))
  end

  defp monotonic_milliseconds, do: System.monotonic_time(:millisecond)
end

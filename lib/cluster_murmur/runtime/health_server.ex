defmodule ClusterMurmur.Runtime.HealthServer do
  @moduledoc """
  Serves fixed value-free liveness, readiness, and startup probes.

  The server accepts only one bounded HTTP/1.1 request per connection. A fixed
  pool limit isolates connection reads from the accept loop, and every request
  shares one absolute receive deadline across TCP segments. It exposes no
  caller-selected handler, upstream request, application data, or diagnostics.
  Readiness and startup succeed only while the fixed production readiness
  service holds a live runtime lease.
  """

  use GenServer

  alias ClusterMurmur.Runtime.{HealthSettings, ReadyMarker}

  @accept_timeout_ms 100
  @receive_timeout_ms 200
  @max_request_bytes 2_048
  @max_connections 32

  @type state :: %{listener: port(), readiness: module(), workers: %{reference() => pid()}}

  @doc "Starts the fixed production health server."
  @spec start_link(HealthSettings.t()) :: GenServer.on_start()
  def start_link(%HealthSettings{} = settings), do: start_link(settings, ReadyMarker)
  def start_link(_settings), do: {:error, :invalid_health_server}

  @doc false
  @spec start_link(term(), module()) :: GenServer.on_start()
  def start_link(%HealthSettings{} = settings, readiness) when is_atom(readiness) do
    with :ok <- HealthSettings.validate(settings),
         true <- Code.ensure_loaded?(readiness),
         true <- function_exported?(readiness, :ready?, 0) do
      GenServer.start_link(__MODULE__, {settings, readiness})
    else
      _failure -> {:error, :invalid_health_server}
    end
  end

  def start_link(_settings, _readiness), do: {:error, :invalid_health_server}

  @impl true
  def init({%HealthSettings{} = settings, readiness}) do
    options = [
      :binary,
      active: false,
      packet: :raw,
      reuseaddr: true,
      nodelay: true,
      backlog: @max_connections,
      recbuf: @max_request_bytes,
      send_timeout: @receive_timeout_ms,
      send_timeout_close: true,
      ip: {0, 0, 0, 0}
    ]

    case :gen_tcp.listen(settings.port, options) do
      {:ok, listener} ->
        send(self(), :accept)
        {:ok, %{listener: listener, readiness: readiness, workers: %{}}}

      {:error, _reason} ->
        {:stop, :invalid_health_server}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listener, @accept_timeout_ms) do
      {:ok, socket} ->
        send(self(), :accept)
        {:noreply, start_connection(socket, state)}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, _reason} ->
        {:stop, :invalid_health_server, state}
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

  defp start_connection(socket, state) when map_size(state.workers) < @max_connections do
    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          {:serve, owned_socket, readiness} ->
            try do
              serve(owned_socket, readiness)
            after
              :gen_tcp.close(owned_socket)
            end
        after
          @receive_timeout_ms -> :ok
        end
      end)

    case :gen_tcp.controlling_process(socket, worker) do
      :ok ->
        send(worker, {:serve, socket, state.readiness})
        %{state | workers: Map.put(state.workers, monitor, worker)}

      {:error, _reason} ->
        :erlang.exit(worker, :kill)
        :erlang.demonitor(monitor, [:flush])
        :gen_tcp.close(socket)
        state
    end
  end

  defp start_connection(socket, state) do
    :gen_tcp.close(socket)
    state
  end

  defp serve(socket, readiness) do
    response =
      case receive_request(socket, <<>>, deadline()) do
        {:ok, request} -> response(request, readiness)
        {:error, :invalid_request} -> bad_request()
      end

    :gen_tcp.send(socket, response)
  end

  defp receive_request(socket, request, deadline) do
    case request_state(request) do
      :complete ->
        reject_buffered_input(socket, request)

      :invalid ->
        {:error, :invalid_request}

      :incomplete ->
        receive_more(socket, request, deadline)
    end
  end

  defp reject_buffered_input(socket, request) do
    case :gen_tcp.recv(socket, 1, 0) do
      {:error, :timeout} -> {:ok, request}
      {:error, :closed} -> {:ok, request}
      _extra_or_failure -> {:error, :invalid_request}
    end
  end

  defp receive_more(socket, request, deadline) do
    remaining_bytes = @max_request_bytes - byte_size(request)
    remaining_ms = deadline - monotonic_milliseconds()

    if remaining_bytes > 0 and remaining_ms > 0 do
      # A positive length prevents one peer burst from materializing an
      # arbitrarily large binary before the total request bound is checked.
      case :gen_tcp.recv(socket, 1, remaining_ms) do
        {:ok, chunk} when byte_size(chunk) <= remaining_bytes ->
          receive_request(socket, request <> chunk, deadline)

        _failure ->
          {:error, :invalid_request}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp request_state(request) do
    case :binary.match(request, "\r\n\r\n") do
      {position, 4} when position + 4 == byte_size(request) -> :complete
      {_position, 4} -> :invalid
      :nomatch -> :incomplete
    end
  end

  defp response(request, readiness)
       when is_binary(request) and byte_size(request) <= @max_request_bytes do
    with true <- String.valid?(request),
         [head, ""] <- :binary.split(request, "\r\n\r\n", [:global]) do
      head |> first_line() |> route(readiness)
    else
      _invalid -> bad_request()
    end
  end

  defp response(_request, _readiness), do: bad_request()

  defp first_line(request) do
    case :binary.split(request, "\r\n") do
      [line | _headers] -> line
      _invalid -> :invalid
    end
  end

  defp route("GET /livez HTTP/1.1", _readiness), do: ok()

  defp route(path, readiness)
       when path in ["GET /readyz HTTP/1.1", "GET /startupz HTTP/1.1"] do
    case readiness.ready?() do
      true -> ok()
      _not_ready -> unavailable()
    end
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp route(_request_line, _readiness), do: not_found()

  defp ok, do: http_response(200, "OK", "ok\n")
  defp unavailable, do: http_response(503, "Service Unavailable", "unavailable\n")
  defp bad_request, do: http_response(400, "Bad Request", "invalid\n")
  defp not_found, do: http_response(404, "Not Found", "not found\n")

  defp http_response(status, reason, body) do
    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "content-type: text/plain; charset=utf-8\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "cache-control: no-store\r\n" <>
      "connection: close\r\n\r\n" <> body
  end

  defp deadline, do: monotonic_milliseconds() + @receive_timeout_ms
  defp monotonic_milliseconds, do: System.monotonic_time(:millisecond)
end

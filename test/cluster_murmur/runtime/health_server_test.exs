defmodule ClusterMurmur.Runtime.HealthServerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.{HealthServer, HealthSettings}

  defmodule AlwaysReady do
    @moduledoc false
    def ready?, do: true
  end

  defmodule NeverReady do
    @moduledoc false
    def ready?, do: false
  end

  defmodule InvalidReadiness do
    @moduledoc false
    def ready?, do: :private_state
  end

  test "serves only fixed value-free liveness, readiness, and startup probes" do
    port = available_port()
    start_server(port, AlwaysReady)

    assert request(port, "GET /livez HTTP/1.1\r\nhost: example.invalid\r\n\r\n") =~
             "HTTP/1.1 200 OK\r\n"

    assert request(port, "GET /readyz HTTP/1.1\r\nhost: example.invalid\r\n\r\n") =~
             "HTTP/1.1 200 OK\r\n"

    assert request(port, "GET /startupz HTTP/1.1\r\nhost: example.invalid\r\n\r\n") =~
             "HTTP/1.1 200 OK\r\n"

    refute request(port, "GET /readyz HTTP/1.1\r\nhost: example.invalid\r\n\r\n") =~
             "example.invalid"
  end

  test "accumulates segmented requests within one absolute deadline" do
    port = available_port()
    start_server(port, AlwaysReady)

    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    assert :ok = :gen_tcp.send(socket, "GET /li")
    Process.sleep(20)
    assert :ok = :gen_tcp.send(socket, "vez HTTP/1.1\r\nhost: example.invalid\r\n\r\n")
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert response =~ "HTTP/1.1 200 OK\r\n"
    :gen_tcp.close(socket)
  end

  test "keeps accepting probes while bounded idle connections time out" do
    port = available_port()
    start_server(port, AlwaysReady)

    idle_sockets =
      for _index <- 1..8 do
        assert {:ok, socket} =
                 :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

        socket
      end

    assert request(port, "GET /livez HTTP/1.1\r\n\r\n") =~ "HTTP/1.1 200 OK\r\n"
    Enum.each(idle_sockets, &:gen_tcp.close/1)
  end

  test "keeps liveness independent and fails readiness closed" do
    unavailable_port = available_port()
    start_server(unavailable_port, NeverReady)

    invalid_port = available_port()
    start_server(invalid_port, InvalidReadiness)

    assert request(unavailable_port, "GET /livez HTTP/1.1\r\n\r\n") =~
             "HTTP/1.1 200 OK\r\n"

    for port <- [unavailable_port, invalid_port], path <- ["readyz", "startupz"] do
      response = request(port, "GET /#{path} HTTP/1.1\r\n\r\n")
      assert response =~ "HTTP/1.1 503 Service Unavailable\r\n"
      assert response =~ "\r\n\r\nunavailable\n"
    end
  end

  test "rejects other methods, paths, incomplete input, and oversized input" do
    port = available_port()
    server = start_server(port, AlwaysReady)

    assert request(port, "POST /livez HTTP/1.1\r\n\r\n") =~ "HTTP/1.1 404 Not Found\r\n"
    assert request(port, "GET /metrics HTTP/1.1\r\n\r\n") =~ "HTTP/1.1 404 Not Found\r\n"

    assert request(port, "GET /livez HTTP/1.1\r\n") =~ "HTTP/1.1 400 Bad Request\r\n"

    pipelined = "GET /livez HTTP/1.1\r\n\r\nGET /readyz HTTP/1.1\r\n\r\n"
    assert request(port, pipelined) =~ "HTTP/1.1 400 Bad Request\r\n"

    oversized_single_burst =
      "GET /livez HTTP/1.1\r\nx-padding: " <>
        String.duplicate("a", 2_048) <> "\r\n\r\n"

    assert request(port, oversized_single_burst) =~ "HTTP/1.1 400 Bad Request\r\n"
    assert Process.alive?(server)
  end

  test "rejects invalid settings and readiness callbacks before listening" do
    assert HealthServer.start_link(nil) == {:error, :invalid_health_server}

    assert HealthServer.start_link(%HealthSettings{port: available_port()}, String) ==
             {:error, :invalid_health_server}
  end

  defp start_server(port, readiness) do
    assert {:ok, server} =
             HealthServer.start_link(%HealthSettings{port: port}, readiness)

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    server
  end

  defp request(port, request) do
    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    assert :ok = :gen_tcp.send(socket, request)

    response =
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, response} -> response
        {:error, :closed} -> ""
      end

    :gen_tcp.close(socket)
    response
  end

  defp available_port do
    assert {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    assert {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end

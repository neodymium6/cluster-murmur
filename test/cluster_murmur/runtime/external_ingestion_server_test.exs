defmodule ClusterMurmur.Runtime.ExternalIngestionServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Ingestion.{BearerAuthentication, HTTPSettings}

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventRecord,
    ExternalEventCommitStore
  }

  alias ClusterMurmur.Runtime.ExternalIngestionServer
  alias ClusterMurmur.Runtime.ExternalIngestionServer.Options

  @token "abcdefghijklmnopqrstuvwxyzABCDEF123456"
  @accepted_at ~U[2026-08-30 15:00:01.000000Z]

  defmodule FixedClock do
    @moduledoc false
    def utc_now, do: ~U[2026-08-30 15:00:01.000000Z]
  end

  test "accepts one authenticated exact event without logging supplied values" do
    test_pid = self()

    commit = fn envelope, configuration, accepted_at ->
      send(test_pid, {:committed, envelope, configuration, accepted_at})
      committed_result(false)
    end

    {port, _server} = start_server(commit)

    log =
      capture_log(fn ->
        assert request(port, event_request()) =~ "HTTP/1.1 202 Accepted\r\n"
        assert_receive {:committed, envelope, configuration, @accepted_at}
        assert envelope.idempotency_key == "retry-identity"
        assert configuration == configuration()
      end)

    assert log =~ "external ingestion request completed"
    assert log =~ "external-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    refute log =~ @token
    refute log =~ "retry-identity"
    refute log =~ "bounded summary"
  end

  test "rejects missing and invalid authorization before body processing" do
    commit = fn _envelope, _configuration, _accepted_at ->
      flunk("unauthorized requests must not commit")
    end

    {port, _server} = start_server(commit)
    body = event_body()

    missing =
      http_request(body, [
        {"host", "example.invalid"},
        {"content-type", "application/json"},
        {"content-length", byte_size(body)}
      ])

    wrong = event_request(authorization: "Bearer " <> String.duplicate("x", 38))

    log =
      capture_log(fn ->
        for candidate <- [missing, wrong] do
          assert request(port, candidate) =~ "HTTP/1.1 401 Unauthorized\r\n"
        end
      end)

    assert log =~ "outcome=rejected"
    assert log =~ "error_class=authentication_failed"
    refute log =~ @token
    refute log =~ "bounded summary"
  end

  test "rejects malformed HTTP, JSON, content type, size, and extra input" do
    commit = fn _envelope, _configuration, _accepted_at ->
      flunk("invalid requests must not commit")
    end

    {port, _server} = start_server(commit)
    body = event_body()

    invalid = [
      {event_request(method: "GET"), 404},
      {event_request(path: "/other"), 404},
      {event_request(content_type: "text/plain"), 415},
      {event_request(body: "not-json"), 400},
      {event_request() <> "extra", 400},
      {event_request(content_length: "+1", body: ""), 400},
      {event_request(content_length: "-1", body: ""), 400},
      {event_request(content_length: 64 * 1_024 + 1, body: ""), 413},
      {String.duplicate("x", 8 * 1_024 + 1), 431}
    ]

    for {candidate, status} <- invalid do
      assert request(port, candidate) =~ "HTTP/1.1 #{status} "
    end

    duplicate_authorization =
      http_request(body, [
        {"host", "example.invalid"},
        {"authorization", "Bearer " <> @token},
        {"Authorization", "Bearer " <> @token},
        {"content-type", "application/json"},
        {"content-length", byte_size(body)}
      ])

    assert request(port, duplicate_authorization) =~ "HTTP/1.1 400 Bad Request\r\n"

    {valid_port, _valid_server} =
      start_server(fn _envelope, _configuration, _accepted_at -> committed_result(false) end)

    capture_log(fn ->
      assert request(valid_port, event_request(content_type: "Application/JSON;charset=UTF-8")) =~
               "HTTP/1.1 202 Accepted\r\n"
    end)
  end

  test "maps durable conflicts and storage uncertainty without response values" do
    cases = [
      {{:error, :external_event_conflict}, 409},
      {{:error, :invalid_external_event_commit}, 400},
      {{:error, :storage_unavailable}, 503},
      {{:error, :unexpected}, 503},
      {committed_result(true), 202}
    ]

    capture_log(fn ->
      for {result, status} <- cases do
        {port, server} = start_server(fn _envelope, _configuration, _accepted_at -> result end)
        response = request(port, event_request())
        assert response =~ "HTTP/1.1 #{status} "
        refute response =~ "external-0123456789abcdef"
        GenServer.stop(server)
      end
    end)
  end

  test "redacts unexpected commit failures behind one unavailable outcome" do
    commit = fn _envelope, _configuration, _accepted_at ->
      raise "bounded summary and private adapter detail"
    end

    {port, _server} = start_server(commit)

    log =
      capture_log(fn ->
        response = request(port, event_request())
        assert response =~ "HTTP/1.1 500 Internal Server Error\r\n"
        refute response =~ "bounded summary"
      end)

    assert log =~ "outcome=unavailable"
    assert log =~ "error_class=unavailable"
    refute log =~ "bounded summary"
    refute log =~ @token
  end

  test "classifies a stalled partial header as a request timeout" do
    {port, _server} =
      start_server(fn _envelope, _configuration, _accepted_at ->
        flunk("partial requests must not commit")
      end)

    log =
      capture_log(fn ->
        assert request(port, "POST /v1/events HTTP/1.1\r\nhost: example.invalid\r\n") =~
                 "HTTP/1.1 408 Request Timeout\r\n"
      end)

    assert log =~ "error_class=timeout"
  end

  test "caps active connections and admitted requests explicitly" do
    {port, _server} =
      start_server(fn _envelope, _configuration, _accepted_at -> committed_result(false) end)

    idle =
      for _index <- 1..16 do
        assert {:ok, socket} =
                 :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

        socket
      end

    assert request(port, event_request()) =~ "HTTP/1.1 429 Too Many Requests\r\n"
    Enum.each(idle, &:gen_tcp.close/1)

    Process.sleep(1_050)

    log =
      capture_log(fn ->
        statuses = for _index <- 1..21, do: request(port, event_request())
        assert Enum.count(statuses, &String.contains?(&1, "202 Accepted")) == 20
        assert List.last(statuses) =~ "429 Too Many Requests"
      end)

    assert length(Regex.scan(~r/error_class=rate_limited/, log)) == 1
  end

  test "rejects invalid options before binding" do
    valid = options(available_port(), fn _, _, _ -> committed_result(false) end)

    for candidate <- [
          nil,
          %{valid | settings: %{valid.settings | port: 0}},
          %{valid | configuration: ExternalIngestion.default()},
          %{valid | clock: String},
          %{valid | commit: nil},
          Map.put(valid, :private, true)
        ] do
      assert ExternalIngestionServer.start_link(candidate) ==
               {:error, :invalid_external_ingestion_server}
    end
  end

  defp start_server(commit) do
    port = available_port()
    assert {:ok, server} = ExternalIngestionServer.start_link(options(port, commit))

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    {port, server}
  end

  defp options(port, commit) do
    {:ok, digest} = BearerAuthentication.digest(@token)

    %Options{
      settings: %HTTPSettings{port: port, token_digest: digest},
      configuration: configuration(),
      clock: FixedClock,
      commit: commit
    }
  end

  defp configuration do
    {:ok, configuration} =
      ExternalIngestion.parse(%{
        "sources" => %{
          "alert-adapter" => %{
            "event_types" => ["component.failed"],
            "groups" => ["operations"],
            "subjects" => ["example-component"],
            "fact_keys" => ["state", "summary"],
            "label_keys" => ["site"]
          }
        }
      })

    configuration
  end

  defp event_request(overrides \\ []) do
    body = Keyword.get(overrides, :body, event_body())
    method = Keyword.get(overrides, :method, "POST")
    path = Keyword.get(overrides, :path, "/v1/events")
    content_type = Keyword.get(overrides, :content_type, "application/json")
    authorization = Keyword.get(overrides, :authorization, "Bearer " <> @token)
    content_length = Keyword.get(overrides, :content_length, byte_size(body))

    request_line = "#{method} #{path} HTTP/1.1"

    http_request(
      body,
      [
        {"host", "example.invalid"},
        {"authorization", authorization},
        {"content-type", content_type},
        {"content-length", content_length}
      ],
      request_line
    )
  end

  defp http_request(body, headers, request_line \\ "POST /v1/events HTTP/1.1") do
    encoded_headers =
      Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    request_line <> "\r\n" <> encoded_headers <> "\r\n" <> body
  end

  defp event_body do
    %{
      "idempotency_key" => "retry-identity",
      "type" => "component.failed",
      "source" => "alert-adapter",
      "subject" => "example-component",
      "group" => "operations",
      "severity" => "warning",
      "occurred_at" => "2026-08-30T15:00:00.000000Z",
      "facts" => %{"state" => "failed", "summary" => "bounded summary"},
      "labels" => %{"site" => "example-site"}
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp committed_result(duplicate?) do
    event_id = "external-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    {:ok,
     %ExternalEventCommitStore.Result{
       event: %EventRecord{id: event_id},
       dispatch: %EventDispatchReceipt{
         event_id: event_id,
         status: :pending,
         enqueued_at: @accepted_at
       },
       duplicate?: duplicate?
     }}
  end

  defp request(port, request) do
    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    assert :ok = :gen_tcp.send(socket, request)
    response = receive_all(socket, <<>>)
    :gen_tcp.close(socket)
    response
  end

  defp receive_all(socket, response) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> receive_all(socket, response <> chunk)
      {:error, :closed} -> response
    end
  end

  defp available_port do
    assert {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    assert {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end

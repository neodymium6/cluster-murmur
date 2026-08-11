defmodule ClusterMurmur.Observers.MCPHTTPRequestTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observers.{MCPHTTPRequest, MCPRequest, MCPSettings}

  @endpoint "https://observer.example.invalid/mcp"
  @token "clearly-fake-observer-token"

  test "encodes one exact stateless target-list request" do
    operation = MCPRequest.list_targets()
    settings = settings()

    assert {:ok, request} = MCPHTTPRequest.encode(operation, settings)

    assert request.method == :post
    assert request.url == @endpoint
    assert request.connect_timeout_ms == 5_000
    assert request.receive_timeout_ms == 15_000
    assert request.overall_timeout_ms == 15_000
    assert request.max_response_bytes == 65_536
    assert MCPHTTPRequest.protocol_version() == "2026-07-28"
    assert MCPHTTPRequest.validate(request, operation, settings) == :ok

    assert request.headers == [
             {"accept", "application/json, text/event-stream"},
             {"authorization", "Bearer " <> @token},
             {"content-type", "application/json"},
             {"mcp-method", "tools/call"},
             {"mcp-name", "observer_list_targets"},
             {"mcp-protocol-version", "2026-07-28"}
           ]

    assert request.json ==
             envelope("observer_list_targets", %{})
  end

  test "encodes only the fixed cluster-health tool and bounded target argument" do
    assert {:ok, operation} = MCPRequest.get_cluster_health("example-cluster")
    settings = settings()

    assert {:ok, request} = MCPHTTPRequest.encode(operation, settings)
    assert {"mcp-name", "kubernetes_get_cluster_health"} in request.headers

    assert request.json ==
             envelope("kubernetes_get_cluster_health", %{"target" => "example-cluster"})

    inspected = inspect(request)
    refute inspected =~ @endpoint
    refute inspected =~ @token
    refute inspected =~ "example-cluster"
    refute inspected =~ "kubernetes_get_cluster_health"
  end

  test "rejects forged operations and settings before encoding" do
    valid_operation = MCPRequest.list_targets()
    valid_settings = settings()

    invalid = [
      {%{valid_operation | tool: "arbitrary_tool"}, valid_settings},
      {Map.put(valid_operation, :path, "/other"), valid_settings},
      {valid_operation, %{valid_settings | endpoint: "http://observer.example.invalid/mcp"}},
      {valid_operation, Map.put(valid_settings, :header, "private")},
      {nil, valid_settings},
      {valid_operation, nil}
    ]

    for {operation, settings} <- invalid do
      assert {:error, _stable_reason} = MCPHTTPRequest.encode(operation, settings)
    end
  end

  test "detects every forged HTTP field during revalidation" do
    operation = MCPRequest.list_targets()
    settings = settings()
    assert {:ok, valid} = MCPHTTPRequest.encode(operation, settings)

    forged = [
      %{valid | method: :get},
      %{valid | url: "https://observer.example.invalid/other"},
      %{valid | headers: [{"authorization", "Bearer private"}]},
      %{valid | json: Map.put(valid.json, "method", "tools/list")},
      %{valid | connect_timeout_ms: 60_000},
      %{valid | receive_timeout_ms: 60_000},
      %{valid | overall_timeout_ms: 60_000},
      %{valid | max_response_bytes: 1_000_000},
      Map.put(valid, :private, true)
    ]

    for request <- forged do
      assert MCPHTTPRequest.validate(request, operation, settings) ==
               {:error, :invalid_mcp_http_request}
    end
  end

  defp settings do
    %MCPSettings{endpoint: @endpoint, bearer_token: @token}
  end

  defp envelope(tool, arguments) do
    %{
      "id" => 1,
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "cluster-murmur",
            "version" => ClusterMurmur.version()
          },
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
        },
        "arguments" => arguments,
        "name" => tool
      }
    }
  end
end

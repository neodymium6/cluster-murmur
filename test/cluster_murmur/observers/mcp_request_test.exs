defmodule ClusterMurmur.Observers.MCPRequestTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observers.MCPRequest

  test "builds only the fixed target-list request" do
    request = MCPRequest.list_targets()

    assert request.operation == :list_targets
    assert request.tool == "observer_list_targets"
    assert request.arguments == %{}
    assert request.overall_timeout_ms == 15_000
    assert request.max_response_bytes == 65_536
    assert MCPRequest.validate(request) == :ok

    refute inspect(request) =~ "observer_list_targets"
  end

  test "builds a fixed cluster-health request from one bounded target ID" do
    assert {:ok, request} = MCPRequest.get_cluster_health("example-cluster")

    assert request.operation == :get_cluster_health
    assert request.tool == "kubernetes_get_cluster_health"
    assert request.arguments == %{"target" => "example-cluster"}
    assert MCPRequest.validate(request) == :ok

    refute inspect(request) =~ "example-cluster"
  end

  test "rejects invalid target IDs and forged request fields" do
    for target <- [nil, "", "UPPER", "two.words", "-prefix", String.duplicate("a", 33)] do
      assert MCPRequest.get_cluster_health(target) == {:error, :invalid_observer_target}
    end

    {:ok, valid} = MCPRequest.get_cluster_health("example-cluster")

    for request <- [
          %{valid | tool: "arbitrary_tool"},
          %{valid | arguments: %{"target" => "example-cluster", "private" => "value"}},
          %{valid | overall_timeout_ms: 60_000},
          %{valid | max_response_bytes: 1_000_000},
          Map.put(valid, :endpoint, "https://example.invalid")
        ] do
      assert MCPRequest.validate(request) == {:error, :invalid_observer_request}
    end
  end
end

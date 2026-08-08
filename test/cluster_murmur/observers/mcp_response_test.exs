defmodule ClusterMurmur.Observers.MCPResponseTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observations.Observation
  alias ClusterMurmur.Observers.{MCPRequest, MCPResponse}

  test "returns only sorted Kubernetes cluster-health target identities" do
    response =
      response(%{
        "targets" => [
          %{
            "id" => "cluster-a",
            "kind" => "kubernetes",
            "capabilities" => [
              "kubernetes.cluster-health",
              "kubernetes.unhealthy-workloads"
            ]
          },
          %{
            "id" => "flux-a",
            "kind" => "flux",
            "capabilities" => ["flux.unhealthy-reconciliations"]
          },
          %{
            "id" => "monitoring-a",
            "kind" => "monitoring",
            "capabilities" => ["monitoring.scrape-health"]
          }
        ]
      })

    assert MCPResponse.decode(MCPRequest.list_targets(), response) ==
             {:ok, [%{id: "cluster-a"}]}

    refute inspect(response) =~ "cluster-a"
  end

  test "normalizes exact healthy, degraded, and partial cluster health" do
    {:ok, request} = MCPRequest.get_cluster_health("cluster-a")

    assert {:ok, %Observation{} = healthy} =
             MCPResponse.decode(request, response(health()))

    assert healthy.source == "cluster-observer-mcp.kubernetes-cluster-health"
    assert healthy.subject == "cluster-a"
    assert healthy.state == :healthy
    assert healthy.observed_at == ~U[2026-08-08 10:00:00Z]
    assert healthy.facts["status"] == "healthy"
    assert healthy.labels["capability"] == "kubernetes.cluster-health"

    degraded =
      health(%{
        "status" => "degraded",
        "nodes" => %{"total" => 3, "ready" => 2},
        "warnings" => [%{"code" => "nodes-not-ready", "count" => 1}]
      })

    assert {:ok, %Observation{state: :unhealthy, facts: %{"status" => "degraded"}}} =
             MCPResponse.decode(request, response(degraded))

    partial =
      health(%{
        "status" => "unknown",
        "partial" => true,
        "warnings" => [%{"code" => "partial-observation", "count" => 1}]
      })

    assert {:ok, %Observation{state: :unhealthy, facts: %{"partial" => true}}} =
             MCPResponse.decode(request, response(partial))
  end

  test "rejects malformed, inconsistent, unsorted, and oversized responses" do
    {:ok, request} = MCPRequest.get_cluster_health("cluster-a")

    invalid_health = [
      Map.put(health(), "target", "cluster-b"),
      Map.put(health(), "status", "degraded"),
      Map.put(health(), "observedAt", "2026-08-08T12:00:00+02:00"),
      Map.put(health(), "nodes", %{"total" => 1, "ready" => 2}),
      Map.put(health(), "workloads", %{"total" => 2, "ready" => 1, "unhealthy" => 0}),
      Map.put(health(), "warnings", [%{"code" => "private-message", "count" => 1}]),
      Map.put(health(), "private", "diagnostic")
    ]

    for body <- invalid_health do
      assert MCPResponse.decode(request, response(body)) == {:error, :invalid_response}
    end

    unsorted_targets = %{
      "targets" => [
        target("zeta", "kubernetes", ["kubernetes.cluster-health"]),
        target("alpha", "kubernetes", ["kubernetes.cluster-health"])
      ]
    }

    assert MCPResponse.decode(MCPRequest.list_targets(), response(unsorted_targets)) ==
             {:error, :invalid_response}

    oversized = %MCPResponse{body: String.duplicate("x", MCPRequest.max_response_bytes() + 1)}
    assert MCPResponse.decode(MCPRequest.list_targets(), oversized) == {:error, :invalid_response}

    assert MCPResponse.decode(%{request | tool: "other"}, response(health())) ==
             {:error, :invalid_response}
  end

  defp response(value), do: %MCPResponse{body: :json.encode(value) |> IO.iodata_to_binary()}

  defp health(overrides \\ %{}) do
    Map.merge(
      %{
        "target" => "cluster-a",
        "observedAt" => "2026-08-08T10:00:00Z",
        "status" => "healthy",
        "nodes" => %{"total" => 3, "ready" => 3},
        "workloads" => %{"total" => 2, "ready" => 2, "unhealthy" => 0},
        "warnings" => [],
        "partial" => false
      },
      overrides
    )
  end

  defp target(id, kind, capabilities) do
    %{"id" => id, "kind" => kind, "capabilities" => capabilities}
  end
end

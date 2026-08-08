defmodule ClusterMurmur.Observers.MCPClientTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observations.Observation
  alias ClusterMurmur.Observers.{MCPClient, MCPRequest, MCPResponse}

  test "lists eligible targets through exactly one fixed transport call" do
    caller = self()

    transport = fn request ->
      send(caller, {:request, request})

      {:ok,
       response(%{
         "targets" => [
           %{
             "id" => "example-cluster",
             "kind" => "kubernetes",
             "capabilities" => ["kubernetes.cluster-health"]
           }
         ]
       })}
    end

    assert MCPClient.list_targets(transport) == {:ok, [%{id: "example-cluster"}]}
    assert_received {:request, %MCPRequest{operation: :list_targets} = request}
    assert MCPRequest.validate(request) == :ok
    refute_receive {:request, _another}
  end

  test "normalizes one cluster health observation through exactly one call" do
    caller = self()

    transport = fn request ->
      send(caller, {:request, request})
      {:ok, response(health())}
    end

    assert {:ok, %Observation{subject: "example-cluster", state: :healthy}} =
             MCPClient.observe_target(transport, "example-cluster")

    assert_received {:request, %MCPRequest{operation: :get_cluster_health} = request}
    assert MCPRequest.validate(request) == :ok
    refute inspect(request) =~ "example-cluster"
    refute_receive {:request, _another}
  end

  test "fails closed before transport for invalid inputs" do
    caller = self()

    transport = fn request ->
      send(caller, {:unexpected, request})
      {:ok, response(health())}
    end

    assert MCPClient.list_targets(:not_a_transport) == {:error, :invalid_request}
    assert MCPClient.observe_target(transport, "UPPER") == {:error, :invalid_request}

    assert MCPClient.observe_target(:not_a_transport, "example-cluster") ==
             {:error, :invalid_request}

    refute_receive {:unexpected, _request}
  end

  test "returns only stable transport failures without retrying" do
    cases = [
      {{:error, :rejected, :authentication_failed}, {:error, :authentication_failed}},
      {{:error, :rejected, :invalid_request}, {:error, :invalid_request}},
      {{:error, :rejected, :rate_limited}, {:error, :rate_limited}},
      {{:error, :not_sent, :timeout}, {:error, :timeout}},
      {{:error, :not_sent, :unavailable}, {:error, :unavailable}},
      {{:error, :outcome_unknown}, {:error, :unavailable}},
      {{:error, :private_diagnostic}, {:error, :invalid_response}},
      {:malformed, {:error, :invalid_response}}
    ]

    for {transport_result, expected} <- cases do
      caller = self()
      reference = make_ref()

      transport = fn _request ->
        send(caller, {:called, reference})
        transport_result
      end

      assert MCPClient.list_targets(transport) == expected
      assert_received {:called, ^reference}
      refute_receive {:called, ^reference}
      refute inspect(expected) =~ "private"
    end
  end

  test "contains raised and thrown transport diagnostics" do
    transports = [
      fn _request -> raise "Private observer diagnostic" end,
      fn _request -> throw("Private observer diagnostic") end,
      fn _request -> exit("Private observer diagnostic") end
    ]

    for transport <- transports do
      result = MCPClient.list_targets(transport)
      assert result == {:error, :unavailable}
      refute inspect(result) =~ "Private"
    end
  end

  defp response(value), do: %MCPResponse{body: :json.encode(value) |> IO.iodata_to_binary()}

  defp health do
    %{
      "target" => "example-cluster",
      "observedAt" => "2026-08-08T10:00:00Z",
      "status" => "healthy",
      "nodes" => %{"total" => 3, "ready" => 3},
      "workloads" => %{"total" => 2, "ready" => 2, "unhealthy" => 0},
      "warnings" => [],
      "partial" => false
    }
  end
end

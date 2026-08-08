defmodule ClusterMurmur.Observers.MCPResponse do
  @moduledoc """
  Decodes bounded Cluster Observer MCP structured results.

  Complete MCP responses remain inside this boundary. Target discovery returns
  only identifiers supporting the fixed Kubernetes cluster-health capability,
  while a cluster-health result becomes one validated application observation.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Events.BoundedJsonDecoder
  alias ClusterMurmur.Observations.{Observation, Validator}
  alias ClusterMurmur.Observers.MCPRequest

  @max_targets 32
  @max_warnings 20
  @source "cluster-observer-mcp.kubernetes-cluster-health"
  @capability "kubernetes.cluster-health"
  @kinds ["kubernetes", "monitoring", "flux"]
  @capabilities [
    "flux.unhealthy-reconciliations",
    "kubernetes.cluster-health",
    "kubernetes.unhealthy-workloads",
    "monitoring.active-alerts",
    "monitoring.scrape-health"
  ]
  @warning_codes ["nodes-not-ready", "partial-observation", "workloads-not-ready"]

  @derive {Inspect, only: []}
  @enforce_keys [:body]
  defstruct [:body]

  @response_keys [:__struct__, :body]
  @response_key_count length(@response_keys)

  @type t :: %__MODULE__{body: binary()}
  @type result ::
          {:ok, [%{id: String.t()}]} | {:ok, Observation.t()} | {:error, :invalid_response}

  @doc "Decodes one exact response according to its independently fixed request."
  @spec decode(term(), term()) :: result()
  def decode(%MCPRequest{} = request, %__MODULE__{} = response) do
    with :ok <- MCPRequest.validate(request),
         true <- exact_bounded_response?(response),
         {:ok, budget} <- BoundedJsonDecoder.initial_budget([]),
         {:ok, decoded, _remaining_budget} <- BoundedJsonDecoder.decode(response.body, budget) do
      decode_operation(request, decoded)
    else
      _failure -> {:error, :invalid_response}
    end
  rescue
    _error -> {:error, :invalid_response}
  catch
    _kind, _reason -> {:error, :invalid_response}
  end

  def decode(_request, _response), do: {:error, :invalid_response}

  defp decode_operation(
         %MCPRequest{operation: :list_targets},
         %{"targets" => targets} = decoded
       )
       when map_size(decoded) == 1 and is_list(targets) do
    with {:ok, normalized} <- validate_targets(targets, nil, MapSet.new(), [], 0) do
      eligible =
        normalized
        |> Enum.filter(fn target ->
          target.kind == "kubernetes" and @capability in target.capabilities
        end)
        |> Enum.map(&%{id: &1.id})

      {:ok, eligible}
    end
  end

  defp decode_operation(
         %MCPRequest{operation: :get_cluster_health, arguments: %{"target" => target_id}},
         decoded
       ) do
    with {:ok, health} <- validate_health(decoded, target_id),
         observation <- to_observation(health),
         :ok <- Validator.validate(observation) do
      {:ok, observation}
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp decode_operation(_request, _decoded), do: {:error, :invalid_response}

  defp exact_bounded_response?(response) do
    map_size(response) == @response_key_count and
      Enum.all?(@response_keys, &Map.has_key?(response, &1)) and
      is_binary(response.body) and byte_size(response.body) <= MCPRequest.max_response_bytes()
  end

  defp validate_targets([], _previous_id, _seen, targets, _count),
    do: {:ok, Enum.reverse(targets)}

  defp validate_targets([target | remaining], previous_id, seen, targets, count)
       when count < @max_targets do
    with {:ok, normalized} <- validate_target(target),
         false <- MapSet.member?(seen, normalized.id),
         true <- previous_id == nil or previous_id < normalized.id do
      validate_targets(
        remaining,
        normalized.id,
        MapSet.put(seen, normalized.id),
        [normalized | targets],
        count + 1
      )
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp validate_targets(_targets, _previous_id, _seen, _normalized, _count),
    do: {:error, :invalid_response}

  defp validate_target(%{"id" => id, "kind" => kind, "capabilities" => capabilities} = target)
       when map_size(target) == 3 and kind in @kinds and is_list(capabilities) do
    with true <- MCPRequest.valid_target_id?(id),
         {:ok, capabilities} <-
           validate_capabilities(capabilities, kind, nil, MapSet.new(), [], 0) do
      {:ok, %{id: id, kind: kind, capabilities: capabilities}}
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp validate_target(_target), do: {:error, :invalid_response}

  defp validate_capabilities([], _kind, _previous, _seen, capabilities, count)
       when count > 0,
       do: {:ok, Enum.reverse(capabilities)}

  defp validate_capabilities(
         [capability | remaining],
         kind,
         previous,
         seen,
         capabilities,
         count
       )
       when count < 2 do
    with true <- capability in @capabilities,
         true <- capability_matches_kind?(capability, kind),
         false <- MapSet.member?(seen, capability),
         true <- previous == nil or previous < capability do
      validate_capabilities(
        remaining,
        kind,
        capability,
        MapSet.put(seen, capability),
        [capability | capabilities],
        count + 1
      )
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp validate_capabilities(_capabilities, _kind, _previous, _seen, _accepted, _count),
    do: {:error, :invalid_response}

  defp capability_matches_kind?("kubernetes." <> _capability, "kubernetes"), do: true
  defp capability_matches_kind?("monitoring." <> _capability, "monitoring"), do: true
  defp capability_matches_kind?("flux." <> _capability, "flux"), do: true
  defp capability_matches_kind?(_capability, _kind), do: false

  defp validate_health(
         %{
           "target" => target,
           "observedAt" => observed_at,
           "status" => status,
           "nodes" => nodes,
           "workloads" => workloads,
           "warnings" => warnings,
           "partial" => partial
         } = health,
         target_id
       )
       when map_size(health) == 7 and target == target_id and
              status in ["healthy", "degraded", "unknown"] and is_boolean(partial) do
    with {:ok, observed_at} <- parse_utc(observed_at),
         {:ok, nodes} <- validate_nodes(nodes),
         {:ok, workloads} <- validate_workloads(workloads),
         {:ok, warnings} <- validate_warnings(warnings, MapSet.new(), [], 0),
         true <- consistent_health?(status, partial, nodes, workloads, warnings) do
      {:ok,
       %{
         target: target,
         observed_at: observed_at,
         status: status,
         nodes: nodes,
         workloads: workloads,
         warnings: warnings,
         partial: partial
       }}
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp validate_health(_health, _target_id), do: {:error, :invalid_response}

  defp validate_nodes(%{"total" => total, "ready" => ready} = nodes)
       when map_size(nodes) == 2 do
    if valid_count?(total) and valid_count?(ready) and ready <= total,
      do: {:ok, %{"total" => total, "ready" => ready}},
      else: {:error, :invalid_response}
  end

  defp validate_nodes(_nodes), do: {:error, :invalid_response}

  defp validate_workloads(
         %{"total" => total, "ready" => ready, "unhealthy" => unhealthy} = workloads
       )
       when map_size(workloads) == 3 do
    if valid_count?(total) and valid_count?(ready) and valid_count?(unhealthy) and
         ready + unhealthy == total,
       do: {:ok, %{"total" => total, "ready" => ready, "unhealthy" => unhealthy}},
       else: {:error, :invalid_response}
  end

  defp validate_workloads(_workloads), do: {:error, :invalid_response}

  defp validate_warnings([], _seen, warnings, _count),
    do: {:ok, Enum.reverse(warnings)}

  defp validate_warnings(
         [%{"code" => code, "count" => count} = warning | remaining],
         seen,
         warnings,
         warning_count
       )
       when map_size(warning) == 2 and warning_count < @max_warnings do
    with true <- code in @warning_codes,
         true <- valid_count?(count) and count > 0,
         false <- MapSet.member?(seen, code) do
      validate_warnings(
        remaining,
        MapSet.put(seen, code),
        [%{"code" => code, "count" => count} | warnings],
        warning_count + 1
      )
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp validate_warnings(_warnings, _seen, _accepted, _count),
    do: {:error, :invalid_response}

  defp consistent_health?(status, partial, nodes, workloads, warnings) do
    expected_warnings =
      []
      |> append_warning(
        nodes["ready"] < nodes["total"],
        "nodes-not-ready",
        nodes["total"] - nodes["ready"]
      )
      |> append_warning(
        workloads["unhealthy"] > 0,
        "workloads-not-ready",
        workloads["unhealthy"]
      )
      |> append_warning(partial, "partial-observation", 1)

    expected_status =
      cond do
        partial -> "unknown"
        expected_warnings == [] -> "healthy"
        true -> "degraded"
      end

    status == expected_status and warnings == expected_warnings
  end

  defp append_warning(warnings, true, code, count),
    do: warnings ++ [%{"code" => code, "count" => count}]

  defp append_warning(warnings, false, _code, _count), do: warnings

  defp to_observation(health) do
    %Observation{
      source: @source,
      subject: health.target,
      state: if(health.status == "healthy", do: :healthy, else: :unhealthy),
      observed_at: health.observed_at,
      facts: %{
        "nodes" => health.nodes,
        "partial" => health.partial,
        "status" => health.status,
        "warnings" => health.warnings,
        "workloads" => health.workloads
      },
      labels: %{
        "capability" => @capability,
        "kind" => "kubernetes",
        "observer" => "cluster-observer-mcp"
      }
    }
  end

  defp parse_utc(value) when is_binary(value) and byte_size(value) in 1..64 do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, 0} -> {:ok, observed_at}
      _invalid -> {:error, :invalid_response}
    end
  end

  defp parse_utc(_value), do: {:error, :invalid_response}

  defp valid_count?(value),
    do: is_integer(value) and value in 0..DomainLimits.max_safe_integer()
end

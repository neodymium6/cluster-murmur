defmodule ClusterMurmur.Observers.MCPClient do
  @moduledoc """
  Executes fixed Cluster Observer MCP operations through one injected transport.

  Each call constructs and revalidates one fixed request, invokes the transport
  exactly once, and returns only normalized application values or stable error
  classes. The adapter never retries or exposes raw MCP responses.
  """

  @behaviour ClusterMurmur.Observers.Client

  alias ClusterMurmur.ExternalError
  alias ClusterMurmur.Observers.{MCPRequest, MCPResponse}

  @type transport :: (MCPRequest.t() -> term())

  @doc "Lists eligible cluster-health targets through the injected transport."
  @impl true
  @spec list_targets(transport()) ::
          {:ok, [%{id: String.t()}]} | {:error, ExternalError.t()}
  def list_targets(transport) when is_function(transport, 1) do
    request = MCPRequest.list_targets()

    with :ok <- MCPRequest.validate(request) do
      execute(transport, request)
    else
      _failure -> {:error, :invalid_request}
    end
  end

  def list_targets(_transport), do: {:error, :invalid_request}

  @doc "Observes one eligible Kubernetes target through the injected transport."
  @impl true
  @spec observe_target(transport(), term()) ::
          {:ok, ClusterMurmur.Observations.Observation.t()}
          | {:error, ExternalError.t()}
  def observe_target(transport, target_id) when is_function(transport, 1) do
    with {:ok, request} <- MCPRequest.get_cluster_health(target_id),
         :ok <- MCPRequest.validate(request) do
      execute(transport, request)
    else
      _failure -> {:error, :invalid_request}
    end
  end

  def observe_target(_transport, _target_id), do: {:error, :invalid_request}

  defp execute(transport, request) do
    case transport.(request) do
      {:ok, %MCPResponse{} = response} ->
        MCPResponse.decode(request, response)

      {:error, :rejected, error_class}
      when error_class in [:authentication_failed, :invalid_request, :rate_limited] ->
        {:error, error_class}

      {:error, :not_sent, error_class} when error_class in [:timeout, :unavailable] ->
        {:error, error_class}

      {:error, :outcome_unknown} ->
        {:error, :unavailable}

      _invalid_transport_result ->
        {:error, :invalid_response}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end
end

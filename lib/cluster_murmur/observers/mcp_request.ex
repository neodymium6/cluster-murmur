defmodule ClusterMurmur.Observers.MCPRequest do
  @moduledoc """
  One fixed read-only request to the Cluster Observer MCP transport.

  Only the target catalog and Kubernetes cluster-health operations are exposed
  by this initial boundary. Callers cannot supply a tool name, arbitrary
  arguments, an endpoint, credentials, or transport options.
  """

  @list_targets_tool "observer_list_targets"
  @cluster_health_tool "kubernetes_get_cluster_health"
  @overall_timeout_ms 15_000
  @max_response_bytes 64 * 1_024
  @target_pattern ~r/\A[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?\z/

  @derive {Inspect, only: [:operation, :overall_timeout_ms, :max_response_bytes]}
  @enforce_keys [:operation, :tool, :arguments, :overall_timeout_ms, :max_response_bytes]
  defstruct [:operation, :tool, :arguments, :overall_timeout_ms, :max_response_bytes]

  @type operation :: :list_targets | :get_cluster_health
  @type t :: %__MODULE__{
          operation: operation(),
          tool: String.t(),
          arguments: %{optional(String.t()) => String.t()},
          overall_timeout_ms: pos_integer(),
          max_response_bytes: pos_integer()
        }
  @type error :: :invalid_observer_request | :invalid_observer_target

  @doc "Returns the fixed maximum structured response size."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc "Builds the endpoint-free target-catalog request."
  @spec list_targets() :: t()
  def list_targets do
    %__MODULE__{
      operation: :list_targets,
      tool: @list_targets_tool,
      arguments: %{},
      overall_timeout_ms: @overall_timeout_ms,
      max_response_bytes: @max_response_bytes
    }
  end

  @doc "Builds one fixed Kubernetes cluster-health request."
  @spec get_cluster_health(term()) :: {:ok, t()} | {:error, :invalid_observer_target}
  def get_cluster_health(target_id) do
    if valid_target_id?(target_id) do
      {:ok,
       %__MODULE__{
         operation: :get_cluster_health,
         tool: @cluster_health_tool,
         arguments: %{"target" => target_id},
         overall_timeout_ms: @overall_timeout_ms,
         max_response_bytes: @max_response_bytes
       }}
    else
      {:error, :invalid_observer_target}
    end
  rescue
    _error -> {:error, :invalid_observer_target}
  catch
    _kind, _reason -> {:error, :invalid_observer_target}
  end

  @doc "Rebuilds and compares every fixed request field before transport."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{operation: :list_targets} = request) do
    if request === list_targets(),
      do: :ok,
      else: {:error, :invalid_observer_request}
  rescue
    _error -> {:error, :invalid_observer_request}
  catch
    _kind, _reason -> {:error, :invalid_observer_request}
  end

  def validate(
        %__MODULE__{
          operation: :get_cluster_health,
          arguments: %{"target" => target_id}
        } = request
      ) do
    case get_cluster_health(target_id) do
      {:ok, expected} when request === expected -> :ok
      {:ok, _expected} -> {:error, :invalid_observer_request}
      {:error, :invalid_observer_target} -> {:error, :invalid_observer_target}
    end
  rescue
    _error -> {:error, :invalid_observer_request}
  catch
    _kind, _reason -> {:error, :invalid_observer_request}
  end

  def validate(_request), do: {:error, :invalid_observer_request}

  @doc false
  @spec valid_target_id?(term()) :: boolean()
  def valid_target_id?(target_id) when is_binary(target_id) do
    byte_size(target_id) in 1..32 and String.valid?(target_id) and
      Regex.match?(@target_pattern, target_id)
  end

  def valid_target_id?(_target_id), do: false
end

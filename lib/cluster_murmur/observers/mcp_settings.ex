defmodule ClusterMurmur.Observers.MCPSettings do
  @moduledoc """
  Loads the fixed Cluster Observer MCP connection settings without connecting.

  The endpoint is read directly from one stable environment variable. The
  bearer credential is read only through the bounded mounted-secret boundary.
  """

  alias ClusterMurmur.Config.MountedSecretReader

  @endpoint_environment "CLUSTER_MURMUR_OBSERVER_MCP_URL"
  @token_file_environment "CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE"
  @max_endpoint_bytes 2_048
  @max_token_bytes 16 * 1_024
  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @derive {Inspect, only: []}
  @enforce_keys [:endpoint, :bearer_token]
  defstruct [:endpoint, :bearer_token]

  @settings_keys [:__struct__, :bearer_token, :endpoint]
  @settings_key_count length(@settings_keys)

  @type t :: %__MODULE__{endpoint: String.t(), bearer_token: String.t()}
  @type environment_reader :: MountedSecretReader.environment_reader()
  @type error ::
          :invalid_mcp_endpoint
          | :invalid_mcp_settings
          | :missing_mcp_endpoint
          | {:bearer_token, MountedSecretReader.error()}

  @doc "Returns the fixed environment variable containing the MCP endpoint."
  def endpoint_environment, do: @endpoint_environment

  @doc "Returns the fixed environment variable containing the token-file path."
  def token_file_environment, do: @token_file_environment

  @doc "Loads endpoint and mounted bearer token without connecting externally."
  @spec load(environment_reader()) :: {:ok, t()} | {:error, error()}
  def load(environment_reader \\ &System.fetch_env/1)

  def load(environment_reader) when is_function(environment_reader, 1) do
    with {:ok, endpoint} <- read_endpoint(environment_reader),
         {:ok, endpoint} <- validate_endpoint(endpoint),
         {:ok, bearer_token} <- read_token(environment_reader),
         true <- valid_token?(bearer_token) do
      {:ok, %__MODULE__{endpoint: endpoint, bearer_token: bearer_token}}
    else
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_mcp_settings}
    end
  rescue
    _error -> {:error, :invalid_mcp_settings}
  catch
    _kind, _reason -> {:error, :invalid_mcp_settings}
  end

  def load(_environment_reader), do: {:error, :invalid_mcp_settings}

  @doc "Revalidates one exact loaded settings value before transport use."
  @spec validate(term()) :: :ok | {:error, :invalid_mcp_settings}
  def validate(%__MODULE__{} = settings) do
    with true <- exact_settings?(settings),
         {:ok, normalized} <- validate_endpoint(settings.endpoint),
         true <- normalized == settings.endpoint,
         true <- valid_token?(settings.bearer_token) do
      :ok
    else
      _failure -> {:error, :invalid_mcp_settings}
    end
  rescue
    _error -> {:error, :invalid_mcp_settings}
  catch
    _kind, _reason -> {:error, :invalid_mcp_settings}
  end

  def validate(_settings), do: {:error, :invalid_mcp_settings}

  defp read_endpoint(environment_reader) do
    case environment_reader.(@endpoint_environment) do
      {:ok, value} when is_binary(value) and byte_size(value) <= @max_endpoint_bytes ->
        if String.valid?(value) do
          case String.trim(value) do
            "" -> {:error, :invalid_mcp_endpoint}
            endpoint -> {:ok, endpoint}
          end
        else
          {:error, :invalid_mcp_endpoint}
        end

      :error ->
        {:error, :missing_mcp_endpoint}

      _result ->
        {:error, :invalid_mcp_endpoint}
    end
  end

  defp read_token(environment_reader) do
    case MountedSecretReader.read(@token_file_environment, environment_reader) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, {:bearer_token, reason}}
    end
  end

  defp validate_endpoint(endpoint)
       when is_binary(endpoint) and byte_size(endpoint) in 1..@max_endpoint_bytes do
    with true <- String.valid?(endpoint),
         false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, endpoint),
         normalized when is_binary(normalized) <- :uri_string.normalize(endpoint),
         {:ok, uri} <- URI.new(normalized),
         true <- valid_uri?(uri) do
      {:ok, normalized}
    else
      _failure -> {:error, :invalid_mcp_endpoint}
    end
  end

  defp validate_endpoint(_endpoint), do: {:error, :invalid_mcp_endpoint}

  defp valid_uri?(%URI{
         scheme: scheme,
         host: host,
         port: port,
         userinfo: nil,
         path: "/mcp",
         query: nil,
         fragment: nil
       })
       when scheme in ["http", "https"] and is_binary(host) and host != "" and
              is_integer(port) and port in 1..65_535 do
    scheme == "https" or String.downcase(host) in @loopback_hosts
  end

  defp valid_uri?(_uri), do: false

  defp valid_token?(token)
       when is_binary(token) and byte_size(token) in 1..@max_token_bytes do
    String.valid?(token) and String.trim(token) == token and
      not Regex.match?(~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, token)
  end

  defp valid_token?(_token), do: false

  defp exact_settings?(settings) do
    map_size(settings) == @settings_key_count and
      Enum.all?(@settings_keys, &Map.has_key?(settings, &1))
  end
end

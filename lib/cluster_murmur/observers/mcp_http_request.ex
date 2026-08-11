defmodule ClusterMurmur.Observers.MCPHTTPRequest do
  @moduledoc """
  Encodes one fixed MCP 2026-07-28 Streamable HTTP tool request.

  The independently fixed observer operation and loaded connection settings
  are revalidated before encoding. Callers cannot choose an HTTP method, MCP
  method, protocol version, endpoint path, headers, or transport limits.
  """

  alias ClusterMurmur.Observers.{MCPRequest, MCPSettings}

  @protocol_version "2026-07-28"
  @json_rpc_id 1
  @connect_timeout_ms 5_000
  @max_request_bytes 16 * 1_024
  @accept {"accept", "application/json, text/event-stream"}
  @content_type {"content-type", "application/json"}
  @mcp_method {"mcp-method", "tools/call"}

  @derive {Inspect,
           only: [
             :method,
             :connect_timeout_ms,
             :receive_timeout_ms,
             :overall_timeout_ms,
             :max_response_bytes
           ]}
  @enforce_keys [
    :method,
    :url,
    :headers,
    :json,
    :connect_timeout_ms,
    :receive_timeout_ms,
    :overall_timeout_ms,
    :max_response_bytes
  ]
  defstruct [
    :method,
    :url,
    :headers,
    :json,
    :connect_timeout_ms,
    :receive_timeout_ms,
    :overall_timeout_ms,
    :max_response_bytes
  ]

  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | map()
  @type t :: %__MODULE__{
          method: :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          json: %{String.t() => json_value()},
          connect_timeout_ms: pos_integer(),
          receive_timeout_ms: pos_integer(),
          overall_timeout_ms: pos_integer(),
          max_response_bytes: pos_integer()
        }
  @type error :: :invalid_mcp_request | :invalid_mcp_settings | :invalid_mcp_http_request

  @doc "Returns the single supported MCP protocol revision."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc "Encodes one fixed observer operation without performing transport."
  @spec encode(term(), term()) :: {:ok, t()} | {:error, error()}
  def encode(%MCPRequest{} = request, %MCPSettings{} = settings) do
    with :ok <- MCPRequest.validate(request),
         :ok <- MCPSettings.validate(settings),
         json <- request_json(request),
         true <- encoded_size(json) <= @max_request_bytes do
      {:ok,
       %__MODULE__{
         method: :post,
         url: settings.endpoint,
         headers: request_headers(request, settings),
         json: json,
         connect_timeout_ms: min(@connect_timeout_ms, request.overall_timeout_ms),
         receive_timeout_ms: request.overall_timeout_ms,
         overall_timeout_ms: request.overall_timeout_ms,
         max_response_bytes: request.max_response_bytes
       }}
    else
      {:error, :invalid_mcp_settings} = error -> error
      _failure -> {:error, :invalid_mcp_request}
    end
  rescue
    _error -> {:error, :invalid_mcp_request}
  catch
    _kind, _reason -> {:error, :invalid_mcp_request}
  end

  def encode(_request, _settings), do: {:error, :invalid_mcp_request}

  @doc "Rebuilds and compares every field immediately before HTTP transport."
  @spec validate(term(), term(), term()) :: :ok | {:error, error()}
  def validate(http_request, request, settings) do
    case encode(request, settings) do
      {:ok, expected} when http_request === expected -> :ok
      {:ok, _expected} -> {:error, :invalid_mcp_http_request}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :invalid_mcp_http_request}
  catch
    _kind, _reason -> {:error, :invalid_mcp_http_request}
  end

  defp request_headers(request, settings) do
    [
      @accept,
      {"authorization", "Bearer " <> settings.bearer_token},
      @content_type,
      @mcp_method,
      {"mcp-name", request.tool},
      {"mcp-protocol-version", @protocol_version}
    ]
  end

  defp request_json(request) do
    %{
      "id" => @json_rpc_id,
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "cluster-murmur",
            "version" => ClusterMurmur.version()
          },
          "io.modelcontextprotocol/protocolVersion" => @protocol_version
        },
        "arguments" => request.arguments,
        "name" => request.tool
      }
    }
  end

  defp encoded_size(value), do: value |> :json.encode() |> IO.iodata_length()
end

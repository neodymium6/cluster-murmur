defmodule ClusterMurmur.Ingestion.HTTPSettings do
  @moduledoc """
  Loads the opt-in loopback ingestion listener settings.

  An empty source policy disables the boundary without reading environment or
  secret values. Enabling sources requires one explicit port and one bounded
  Bearer credential from a mounted secret file. Only its digest is retained.
  """

  alias ClusterMurmur.Config.{ExternalIngestion, MountedSecretReader}
  alias ClusterMurmur.Ingestion.BearerAuthentication

  @derive {Inspect, only: [:port]}
  @enforce_keys [:port, :token_digest]
  defstruct [:port, :token_digest]

  @port_environment "CLUSTER_MURMUR_INGESTION_PORT"
  @token_file_environment "CLUSTER_MURMUR_INGESTION_TOKEN_FILE"
  @settings_keys [:__struct__, :port, :token_digest]
  @settings_key_count length(@settings_keys)

  @type t :: %__MODULE__{port: 1..65_535, token_digest: binary()}
  @type loaded :: :disabled | t()
  @type error :: :invalid_external_ingestion_http_settings
  @type environment_reader :: MountedSecretReader.environment_reader()

  @doc "Loads disabled state or the complete loopback listener settings."
  @spec load(term(), environment_reader()) :: {:ok, loaded()} | {:error, error()}
  def load(configuration, environment_reader \\ &System.fetch_env/1)

  def load(%ExternalIngestion{sources: sources} = configuration, environment_reader)
      when is_function(environment_reader, 1) do
    with :ok <- ExternalIngestion.validate(configuration) do
      if map_size(sources) == 0,
        do: {:ok, :disabled},
        else: load_enabled(environment_reader)
    else
      _failure -> {:error, :invalid_external_ingestion_http_settings}
    end
  rescue
    _error -> {:error, :invalid_external_ingestion_http_settings}
  catch
    _kind, _reason -> {:error, :invalid_external_ingestion_http_settings}
  end

  def load(_configuration, _environment_reader),
    do: {:error, :invalid_external_ingestion_http_settings}

  @doc "Revalidates one exact enabled listener setting."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{port: port, token_digest: token_digest} = settings) do
    if map_size(settings) == @settings_key_count and
         Enum.all?(@settings_keys, &Map.has_key?(settings, &1)) and
         is_integer(port) and port in 1..65_535 and is_binary(token_digest) and
         byte_size(token_digest) == 32 do
      :ok
    else
      {:error, :invalid_external_ingestion_http_settings}
    end
  end

  def validate(_settings), do: {:error, :invalid_external_ingestion_http_settings}

  defp load_enabled(environment_reader) do
    with {:ok, port} <- read_port(environment_reader),
         {:ok, token} <-
           MountedSecretReader.read(@token_file_environment, environment_reader),
         {:ok, token_digest} <- BearerAuthentication.digest(token),
         settings = %__MODULE__{port: port, token_digest: token_digest},
         :ok <- validate(settings) do
      {:ok, settings}
    else
      _failure -> {:error, :invalid_external_ingestion_http_settings}
    end
  end

  defp read_port(environment_reader) do
    case environment_reader.(@port_environment) do
      {:ok, value} when is_binary(value) and byte_size(value) in 1..5 ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 -> {:ok, port}
          _invalid -> {:error, :invalid_external_ingestion_http_settings}
        end

      _failure ->
        {:error, :invalid_external_ingestion_http_settings}
    end
  end
end

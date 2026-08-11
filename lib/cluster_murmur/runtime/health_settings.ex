defmodule ClusterMurmur.Runtime.HealthSettings do
  @moduledoc """
  Loads the fixed operational probe listener port.

  The deployment selects only one TCP port. The application fixes the listener
  address, paths, methods, response bodies, timeouts, and readiness source.
  """

  @derive {Inspect, only: [:port]}
  @enforce_keys [:port]
  defstruct [:port]

  @environment_variable "CLUSTER_MURMUR_HEALTH_PORT"

  @type t :: %__MODULE__{port: 1..65_535}
  @type environment_reader :: (String.t() -> {:ok, String.t()} | :error)

  @doc "Loads the explicit production health listener port."
  @spec load(environment_reader()) :: {:ok, t()} | {:error, :invalid_health_settings}
  def load(environment_reader \\ &System.fetch_env/1)

  def load(environment_reader) when is_function(environment_reader, 1) do
    with {:ok, value} <- read(environment_reader),
         {port, ""} <- Integer.parse(value),
         settings = %__MODULE__{port: port},
         :ok <- validate(settings) do
      {:ok, settings}
    else
      _failure -> {:error, :invalid_health_settings}
    end
  rescue
    _error -> {:error, :invalid_health_settings}
  catch
    _kind, _reason -> {:error, :invalid_health_settings}
  end

  def load(_environment_reader), do: {:error, :invalid_health_settings}

  @doc "Validates one exact health listener setting."
  @spec validate(term()) :: :ok | {:error, :invalid_health_settings}
  def validate(%__MODULE__{port: port} = settings) do
    if map_size(settings) == 2 and is_integer(port) and port in 1..65_535,
      do: :ok,
      else: {:error, :invalid_health_settings}
  end

  def validate(_settings), do: {:error, :invalid_health_settings}

  defp read(environment_reader) do
    case environment_reader.(@environment_variable) do
      {:ok, value} when is_binary(value) and byte_size(value) in 1..5 -> {:ok, value}
      _failure -> {:error, :invalid_health_settings}
    end
  end
end

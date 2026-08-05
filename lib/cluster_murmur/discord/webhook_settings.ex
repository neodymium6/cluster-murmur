defmodule ClusterMurmur.Discord.WebhookSettings do
  @moduledoc """
  Loads and validates the single configured Discord incoming-webhook URL.

  The credential is read through the bounded mounted-secret boundary from an
  exact public routing value. This module does not execute the webhook or add
  publication query parameters.
  """

  alias ClusterMurmur.Config.{MountedSecretReader, Routing}

  @routing_keys Routing.__struct__() |> Map.keys()
  @routing_key_count length(@routing_keys)
  @max_url_bytes 2_048
  @webhook_path_pattern ~r|\A/api/(?:v10/)?webhooks/[0-9]{1,32}/[A-Za-z0-9._-]{1,512}\z|

  @derive {Inspect, only: []}
  @enforce_keys [:url]
  defstruct [:url]

  @settings_keys [:__struct__, :url]
  @settings_key_count length(@settings_keys)

  @type t :: %__MODULE__{url: String.t()}
  @type environment_reader :: MountedSecretReader.environment_reader()
  @type error ::
          :invalid_webhook_settings
          | :invalid_webhook_url
          | {:webhook, MountedSecretReader.error()}

  @doc "Loads one validated Discord webhook credential without connecting."
  @spec load(term(), environment_reader()) :: {:ok, t()} | {:error, error()}
  def load(routing, environment_reader \\ &System.fetch_env/1)

  def load(%Routing{} = routing, environment_reader)
      when is_function(environment_reader, 1) do
    with :ok <- validate_routing(routing),
         {:ok, url} <- read_webhook(routing.webhook_secret_file_env, environment_reader),
         :ok <- validate_url(url) do
      {:ok, %__MODULE__{url: url}}
    end
  rescue
    _error -> {:error, :invalid_webhook_settings}
  catch
    _kind, _reason -> {:error, :invalid_webhook_settings}
  end

  def load(_routing, _environment_reader), do: {:error, :invalid_webhook_settings}

  @doc "Revalidates one exact loaded webhook setting at a runtime boundary."
  @spec validate(term()) :: :ok | {:error, :invalid_webhook_settings}
  def validate(%__MODULE__{} = settings) do
    if map_size(settings) == @settings_key_count and
         Enum.all?(@settings_keys, &Map.has_key?(settings, &1)) and
         validate_url(settings.url) == :ok do
      :ok
    else
      {:error, :invalid_webhook_settings}
    end
  rescue
    _error -> {:error, :invalid_webhook_settings}
  catch
    _kind, _reason -> {:error, :invalid_webhook_settings}
  end

  def validate(_settings), do: {:error, :invalid_webhook_settings}

  defp validate_routing(routing) do
    if map_size(routing) == @routing_key_count and
         Enum.all?(@routing_keys, &Map.has_key?(routing, &1)) do
      :ok
    else
      {:error, :invalid_webhook_settings}
    end
  end

  defp read_webhook(environment_variable_name, environment_reader) do
    case MountedSecretReader.read(environment_variable_name, environment_reader) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, {:webhook, reason}}
    end
  end

  defp validate_url(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    with true <- String.valid?(url),
         false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, url),
         {:ok, uri} <- URI.new(url),
         true <- valid_uri?(uri) do
      :ok
    else
      _failure -> {:error, :invalid_webhook_url}
    end
  end

  defp validate_url(_url), do: {:error, :invalid_webhook_url}

  defp valid_uri?(%URI{
         scheme: "https",
         host: host,
         port: 443,
         userinfo: nil,
         path: path,
         query: nil,
         fragment: nil
       })
       when is_binary(host) and is_binary(path) do
    String.downcase(host) == "discord.com" and Regex.match?(@webhook_path_pattern, path)
  end

  defp valid_uri?(_uri), do: false
end

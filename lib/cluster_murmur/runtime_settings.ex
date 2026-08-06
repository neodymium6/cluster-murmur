defmodule ClusterMurmur.RuntimeSettings do
  @moduledoc """
  Loads the complete secret-bearing runtime settings before external startup.

  The aggregate accepts only a normalized startup configuration, delegates
  deployment-value reads to the narrow provider and webhook boundaries, and
  performs no network connection or publication.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Discord.WebhookSettings
  alias ClusterMurmur.Generation.ProviderSettings

  @settings_keys [:__struct__, :provider_settings, :webhook_settings]
  @settings_key_count length(@settings_keys)

  @derive {Inspect, only: []}
  @enforce_keys [:provider_settings, :webhook_settings]
  defstruct [:provider_settings, :webhook_settings]

  @type t :: %__MODULE__{
          provider_settings: ProviderSettings.t(),
          webhook_settings: WebhookSettings.t()
        }

  @type environment_reader :: ClusterMurmur.Config.MountedSecretReader.environment_reader()
  @type error ::
          :invalid_runtime_settings
          | {:provider, ProviderSettings.error()}
          | {:webhook, WebhookSettings.error()}

  @doc "Loads all deployment settings without making an external connection."
  @spec load(term(), environment_reader()) :: {:ok, t()} | {:error, error()}
  def load(configuration, environment_reader \\ &System.fetch_env/1)

  def load(%Configuration{} = configuration, environment_reader)
      when is_function(environment_reader, 1) do
    with :ok <- validate_configuration(configuration),
         {:ok, provider_settings} <-
           annotate(ProviderSettings.load(configuration.llm, environment_reader), :provider),
         {:ok, webhook_settings} <-
           annotate(WebhookSettings.load(configuration.routing, environment_reader), :webhook) do
      settings = %__MODULE__{
        provider_settings: provider_settings,
        webhook_settings: webhook_settings
      }

      case validate(settings) do
        :ok -> {:ok, settings}
        {:error, :invalid_runtime_settings} = error -> error
      end
    end
  rescue
    _error -> {:error, :invalid_runtime_settings}
  catch
    _kind, _reason -> {:error, :invalid_runtime_settings}
  end

  def load(_configuration, _environment_reader), do: {:error, :invalid_runtime_settings}

  @doc "Revalidates one exact aggregate before runtime construction."
  @spec validate(term()) :: :ok | {:error, :invalid_runtime_settings}
  def validate(%__MODULE__{} = settings) do
    if exact_settings?(settings) and ProviderSettings.validate(settings.provider_settings) == :ok and
         WebhookSettings.validate(settings.webhook_settings) == :ok do
      :ok
    else
      {:error, :invalid_runtime_settings}
    end
  rescue
    _error -> {:error, :invalid_runtime_settings}
  catch
    _kind, _reason -> {:error, :invalid_runtime_settings}
  end

  def validate(_settings), do: {:error, :invalid_runtime_settings}

  defp validate_configuration(configuration) do
    case Configuration.validate(configuration) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_runtime_settings}
    end
  end

  defp exact_settings?(settings) do
    map_size(settings) == @settings_key_count and
      Enum.all?(@settings_keys, &Map.has_key?(settings, &1))
  end

  defp annotate({:ok, value}, _boundary), do: {:ok, value}
  defp annotate({:error, reason}, boundary), do: {:error, {boundary, reason}}
end

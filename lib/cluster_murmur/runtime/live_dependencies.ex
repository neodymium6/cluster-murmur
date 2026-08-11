defmodule ClusterMurmur.Runtime.LiveDependencies do
  @moduledoc """
  Builds the fixed live external capabilities from validated startup inputs.

  Construction captures each independently validated setting in its narrow
  one-argument transport and creates the read-only observer client. It performs
  no network I/O, persistence access, worker start, or caller-selected adapter
  resolution.
  """

  alias ClusterMurmur.Discord.{WebhookHTTPTransport, WebhookPublisher}

  alias ClusterMurmur.Generation.{
    OpenAICompatibleHTTPTransport,
    OpenAICompatibleProvider,
    Provider
  }

  alias ClusterMurmur.Observers.{Client, MCPClient, MCPHTTPTransport}
  alias ClusterMurmur.RuntimeSettings
  alias ClusterMurmur.Startup
  alias ClusterMurmur.Startup.Prepared

  @derive {Inspect, only: [:observer_client, :provider, :publisher]}
  @enforce_keys [
    :observer_client,
    :provider,
    :publisher,
    :generation_transport,
    :publication_transport
  ]
  defstruct [
    :observer_client,
    :provider,
    :publisher,
    :generation_transport,
    :publication_transport
  ]

  @type t :: %__MODULE__{
          observer_client: Client.t(),
          provider: module(),
          publisher: module(),
          generation_transport: Provider.transport(),
          publication_transport: ClusterMurmur.Discord.Publisher.transport()
        }

  @doc "Builds the fixed network-free capability bundle for later worker assembly."
  @spec build(term()) :: {:ok, t()} | {:error, :invalid_live_dependencies}
  def build(%Prepared{runtime_settings: %RuntimeSettings{} = settings} = prepared) do
    with :ok <- Startup.validate(prepared),
         {:ok, observer_client} <- build_observer_client(settings) do
      {:ok,
       %__MODULE__{
         observer_client: observer_client,
         provider: OpenAICompatibleProvider,
         publisher: WebhookPublisher,
         generation_transport: generation_transport(settings),
         publication_transport: publication_transport(settings)
       }}
    else
      _failure -> {:error, :invalid_live_dependencies}
    end
  rescue
    _error -> {:error, :invalid_live_dependencies}
  catch
    _kind, _reason -> {:error, :invalid_live_dependencies}
  end

  def build(_prepared), do: {:error, :invalid_live_dependencies}

  defp build_observer_client(settings) do
    observer_settings = settings.observer_settings
    transport = fn request -> MCPHTTPTransport.execute(request, observer_settings) end
    Client.new(MCPClient, transport)
  end

  defp generation_transport(settings) do
    provider_settings = settings.provider_settings
    fn request -> OpenAICompatibleHTTPTransport.execute(request, provider_settings) end
  end

  defp publication_transport(settings) do
    webhook_settings = settings.webhook_settings
    fn request -> WebhookHTTPTransport.execute(request, webhook_settings) end
  end
end

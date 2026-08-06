defmodule ClusterMurmur.Generation.OpenAICompatibleProvider do
  @moduledoc """
  Calls one OpenAI-compatible generation transport through fixed boundaries.

  The adapter revalidates the complete encoded request immediately before the
  injected transport, performs exactly one transport invocation, and returns
  only generated text or a stable external error class. It does not retry,
  normalize content, persist state, or expose provider diagnostics.
  """

  @behaviour ClusterMurmur.Generation.Provider

  alias ClusterMurmur.Generation.{
    OpenAICompatibleRequest,
    OpenAICompatibleResponse,
    PromptRequest,
    Provider,
    ProviderSettings
  }

  @doc "Executes one fixed generation request through an injected transport."
  @impl true
  @spec generate(PromptRequest.t(), ProviderSettings.t(), Provider.transport()) ::
          {:ok, String.t()} | {:error, ClusterMurmur.ExternalError.t()}
  def generate(%PromptRequest{} = prompt, %ProviderSettings{} = settings, transport)
      when is_function(transport, 1) do
    with {:ok, request} <- OpenAICompatibleRequest.encode(prompt, settings),
         :ok <- OpenAICompatibleRequest.validate(request, prompt, settings) do
      execute(transport, request)
    else
      _invalid_input -> {:error, :invalid_request}
    end
  end

  def generate(_prompt, _settings, _transport), do: {:error, :invalid_request}

  defp execute(transport, request) do
    case transport.(request) do
      {:ok, %OpenAICompatibleResponse{} = response} ->
        OpenAICompatibleResponse.decode(response)

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

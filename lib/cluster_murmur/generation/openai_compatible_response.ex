defmodule ClusterMurmur.Generation.OpenAICompatibleResponse do
  @moduledoc """
  Decodes one bounded OpenAI-compatible response into text or a stable error.

  Raw bodies and provider diagnostics never cross this boundary. Successful
  response JSON passes the shared bounded decoder before this module extracts
  only the single message content requested by the application.
  """

  alias ClusterMurmur.Events.BoundedJsonDecoder
  alias ClusterMurmur.ExternalError
  alias ClusterMurmur.Generation.OpenAICompatibleRequest

  @derive {Inspect, only: [:status]}
  @enforce_keys [:status, :body]
  defstruct [:status, :body]

  @response_keys [:__struct__, :body, :status]
  @response_key_count length(@response_keys)

  @type t :: %__MODULE__{status: integer(), body: binary()}
  @type result :: {:ok, String.t()} | {:error, ExternalError.t()}

  @doc "Classifies one exact bounded response without exposing its raw body."
  @spec decode(term()) :: result()
  def decode(%__MODULE__{} = response) do
    if exact_bounded_response?(response),
      do: decode_status(response.status, response.body),
      else: {:error, :invalid_response}
  rescue
    _error -> {:error, :invalid_response}
  catch
    _kind, _reason -> {:error, :invalid_response}
  end

  def decode(_response), do: {:error, :invalid_response}

  defp exact_bounded_response?(response) do
    map_size(response) == @response_key_count and
      Enum.all?(@response_keys, &Map.has_key?(response, &1)) and
      is_integer(response.status) and response.status in 100..599 and
      is_binary(response.body) and
      byte_size(response.body) <= OpenAICompatibleRequest.max_response_bytes()
  end

  defp decode_status(200, body), do: decode_success(body)

  defp decode_status(status, _body) when status in [401, 403],
    do: {:error, :authentication_failed}

  defp decode_status(408, _body), do: {:error, :timeout}
  defp decode_status(429, _body), do: {:error, :rate_limited}
  defp decode_status(status, _body) when status in 400..499, do: {:error, :invalid_request}
  defp decode_status(status, _body) when status in 500..599, do: {:error, :unavailable}
  defp decode_status(_status, _body), do: {:error, :invalid_response}

  defp decode_success(body) do
    with {:ok, budget} <- BoundedJsonDecoder.initial_budget([]),
         {:ok, decoded, _remaining_budget} <- BoundedJsonDecoder.decode(body, budget),
         {:ok, content} <- extract_content(decoded) do
      {:ok, content}
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp extract_content(%{
         "choices" => [
           %{"message" => %{"content" => content}}
         ]
       })
       when is_binary(content),
       do: {:ok, content}

  defp extract_content(_decoded), do: {:error, :invalid_response}
end

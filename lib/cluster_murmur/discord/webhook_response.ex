defmodule ClusterMurmur.Discord.WebhookResponse do
  @moduledoc """
  Decodes one bounded Discord webhook response into a message ID or stable error.

  Raw bodies and Discord diagnostics never cross this boundary. Successful
  response JSON is decoded through the shared bounded decoder, and only one
  canonical Discord message ID is returned.
  """

  alias ClusterMurmur.Discord.WebhookRequest
  alias ClusterMurmur.Events.BoundedJsonDecoder
  alias ClusterMurmur.ExternalError

  @snowflake_pattern ~r/\A[1-9][0-9]{0,19}\z/
  @max_snowflake 18_446_744_073_709_551_615

  @derive {Inspect, only: [:status]}
  @enforce_keys [:status, :body]
  defstruct [:status, :body]

  @response_keys [:__struct__, :status, :body]
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
      byte_size(response.body) <= WebhookRequest.max_response_bytes()
  end

  defp decode_status(200, body), do: decode_success(body)

  defp decode_status(status, _body) when status in [401, 403, 404],
    do: {:error, :authentication_failed}

  defp decode_status(408, _body), do: {:error, :timeout}
  defp decode_status(429, _body), do: {:error, :rate_limited}
  defp decode_status(status, _body) when status in 400..499, do: {:error, :invalid_request}
  defp decode_status(status, _body) when status in 500..599, do: {:error, :unavailable}
  defp decode_status(_status, _body), do: {:error, :invalid_response}

  defp decode_success(body) do
    with {:ok, budget} <- BoundedJsonDecoder.initial_budget([]),
         {:ok, %{"id" => message_id}, _remaining_budget} <-
           BoundedJsonDecoder.decode(body, budget),
         true <- valid_message_id?(message_id) do
      {:ok, message_id}
    else
      _failure -> {:error, :invalid_response}
    end
  end

  defp valid_message_id?(message_id) when is_binary(message_id) do
    String.valid?(message_id) and Regex.match?(@snowflake_pattern, message_id) and
      canonical_snowflake?(message_id)
  end

  defp valid_message_id?(_message_id), do: false

  defp canonical_snowflake?(message_id) do
    case Integer.parse(message_id) do
      {value, ""} when value in 1..@max_snowflake -> Integer.to_string(value) == message_id
      _invalid -> false
    end
  end
end

defmodule ClusterMurmur.Discord.WebhookHTTPResponseAccumulator do
  @moduledoc false

  alias ClusterMurmur.Discord.WebhookResponse

  defstruct body: [],
            body_bytes: 0,
            headers: nil,
            informational: false,
            status: nil

  @type t :: %__MODULE__{
          body: [binary()],
          body_bytes: non_neg_integer(),
          headers: nil | [{binary(), binary()}],
          informational: boolean(),
          status: nil | integer()
        }

  @type result :: {:ok, WebhookResponse.t()} | {:error, :outcome_unknown}

  @doc false
  @spec reduce(t(), list(), reference(), pos_integer()) ::
          {:continue, t()} | {:done, result()}
  def reduce(%__MODULE__{} = state, responses, reference, max_response_bytes)
      when is_list(responses) and is_reference(reference) and is_integer(max_response_bytes) and
             max_response_bytes > 0 do
    Enum.reduce_while(responses, {:continue, state}, fn response, {:continue, current} ->
      case reduce_response(current, response, reference, max_response_bytes) do
        {:continue, next} -> {:cont, {:continue, next}}
        {:done, result} -> {:halt, {:done, result}}
      end
    end)
  rescue
    _error -> {:done, {:error, :outcome_unknown}}
  catch
    _kind, _reason -> {:done, {:error, :outcome_unknown}}
  end

  def reduce(_state, _responses, _reference, _max_response_bytes),
    do: {:done, {:error, :outcome_unknown}}

  defp reduce_response(state, {:status, reference, status}, reference, _max)
       when status in 100..199 and is_nil(state.status) do
    {:continue, %{state | informational: true}}
  end

  defp reduce_response(state, {:status, reference, status}, reference, _max)
       when status in 200..599 and is_nil(state.status) and not state.informational do
    {:continue, %{state | status: status}}
  end

  defp reduce_response(state, {:headers, reference, _headers}, reference, _max)
       when state.informational do
    {:continue, %{state | informational: false}}
  end

  defp reduce_response(state, {:headers, reference, headers}, reference, _max)
       when is_integer(state.status) and is_nil(state.headers) and is_list(headers) do
    {:continue, %{state | headers: headers}}
  end

  defp reduce_response(state, {:headers, reference, _trailers}, reference, _max)
       when is_list(state.headers),
       do: {:continue, state}

  defp reduce_response(state, {:data, reference, data}, reference, max)
       when is_list(state.headers) and is_binary(data) do
    next_bytes = state.body_bytes + byte_size(data)

    if next_bytes <= max,
      do: {:continue, %{state | body: [data | state.body], body_bytes: next_bytes}},
      else: {:done, {:error, :outcome_unknown}}
  end

  defp reduce_response(state, {:done, reference}, reference, _max)
       when is_integer(state.status) and is_list(state.headers) do
    {:done, decode_response(state)}
  end

  defp reduce_response(_state, {:error, reference, _reason}, reference, _max),
    do: {:done, {:error, :outcome_unknown}}

  defp reduce_response(_state, _response, _reference, _max),
    do: {:done, {:error, :outcome_unknown}}

  defp decode_response(state) do
    body = state.body |> Enum.reverse() |> IO.iodata_to_binary()

    with :ok <- validate_response_media_type(state.status, state.headers) do
      {:ok, %WebhookResponse{status: state.status, body: body}}
    else
      _invalid -> {:error, :outcome_unknown}
    end
  end

  defp validate_response_media_type(200, headers), do: require_json_media_type(headers)
  defp validate_response_media_type(_status, _headers), do: :ok

  defp require_json_media_type(headers) do
    case content_types(headers) do
      [value] -> validate_json_media_type(value)
      _missing_or_multiple -> {:error, :invalid_response}
    end
  end

  defp content_types(headers) do
    for {name, value} <- headers,
        is_binary(name),
        is_binary(value),
        String.valid?(name),
        String.downcase(name) == "content-type",
        do: value
  end

  defp validate_json_media_type(value) when is_binary(value) do
    if String.valid?(value),
      do: validate_normalized_json_media_type(value),
      else: {:error, :invalid_response}
  end

  defp validate_json_media_type(_value), do: {:error, :invalid_response}

  defp validate_normalized_json_media_type(value) do
    media_type =
      value
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    if media_type == "application/json", do: :ok, else: {:error, :invalid_response}
  end
end

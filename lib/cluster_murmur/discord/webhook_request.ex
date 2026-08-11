defmodule ClusterMurmur.Discord.WebhookRequest do
  @moduledoc """
  A fixed bounded request for one validated Discord webhook publication.

  The request always asks Discord for a response body, disables mention
  parsing, and carries fixed transport limits. Callers must revalidate the
  complete request against independent current inputs immediately before
  transport; the public struct is not itself an execution capability.
  """

  alias ClusterMurmur.Discord.{PublicationPlanValidator, WebhookSettings}
  alias ClusterMurmur.Discord.PublicationPlanner.Plan
  alias ClusterMurmur.Messages.Validator, as: MessageValidator

  @content_type {"content-type", "application/json"}
  @wait_query {"wait", "true"}
  @connect_timeout_ms 5_000
  @receive_timeout_ms 10_000
  @overall_timeout_ms 15_000
  @max_response_bytes 16 * 1_024
  @max_content_characters 2_000
  @max_username_bytes 128
  @max_username_characters 80
  @max_avatar_bytes 2_048

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
    :query,
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
    :query,
    :json,
    :connect_timeout_ms,
    :receive_timeout_ms,
    :overall_timeout_ms,
    :max_response_bytes
  ]

  @request_keys [
    :__struct__,
    :connect_timeout_ms,
    :headers,
    :json,
    :max_response_bytes,
    :method,
    :overall_timeout_ms,
    :query,
    :receive_timeout_ms,
    :url
  ]
  @request_key_count length(@request_keys)

  @type json_value :: String.t() | boolean() | [json_value()] | %{String.t() => json_value()}
  @type t :: %__MODULE__{
          method: :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          query: [{String.t(), String.t()}],
          json: %{String.t() => json_value()},
          connect_timeout_ms: pos_integer(),
          receive_timeout_ms: pos_integer(),
          overall_timeout_ms: pos_integer(),
          max_response_bytes: pos_integer()
        }

  @type error :: :invalid_publication_plan | :invalid_webhook_request

  @doc "Returns the fixed maximum response bytes an adapter may accept."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc "Encodes one revalidated publication plan into a fixed webhook request."
  @spec encode(term(), term(), term(), term()) :: {:ok, t()} | {:error, error()}
  def encode(%Plan{} = plan, current_record, current_persona, current_settings) do
    with :ok <-
           PublicationPlanValidator.validate(
             plan,
             current_record,
             current_persona,
             current_settings
           ) do
      {:ok,
       %__MODULE__{
         method: :post,
         url: current_settings.url,
         headers: [@content_type],
         query: [@wait_query],
         json: encode_payload(plan.payload),
         connect_timeout_ms: @connect_timeout_ms,
         receive_timeout_ms: @receive_timeout_ms,
         overall_timeout_ms: @overall_timeout_ms,
         max_response_bytes: @max_response_bytes
       }}
    end
  rescue
    _error -> {:error, :invalid_publication_plan}
  catch
    _kind, _reason -> {:error, :invalid_publication_plan}
  end

  def encode(_plan, _current_record, _current_persona, _current_settings),
    do: {:error, :invalid_publication_plan}

  @doc "Revalidates the complete fixed request immediately before transport."
  @spec validate(term(), term(), term(), term(), term()) :: :ok | {:error, error()}
  def validate(request, plan, current_record, current_persona, current_settings) do
    case encode(plan, current_record, current_persona, current_settings) do
      {:ok, expected} when request == expected -> :ok
      {:ok, _expected} -> {:error, :invalid_webhook_request}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :invalid_webhook_request}
  catch
    _kind, _reason -> {:error, :invalid_webhook_request}
  end

  @doc "Revalidates the fixed request against transport-captured webhook settings."
  @spec validate_for_transport(term(), term()) :: :ok | {:error, :invalid_webhook_request}
  def validate_for_transport(%__MODULE__{} = request, %WebhookSettings{} = settings) do
    with true <- exact_request?(request),
         true <- request.method == :post,
         :ok <- WebhookSettings.validate(settings),
         true <- request.url == settings.url,
         true <- request.headers == [@content_type],
         true <- request.query == [@wait_query],
         :ok <- validate_payload(request.json),
         true <- request.connect_timeout_ms == @connect_timeout_ms,
         true <- request.receive_timeout_ms == @receive_timeout_ms,
         true <- request.overall_timeout_ms == @overall_timeout_ms,
         true <- request.max_response_bytes == @max_response_bytes do
      :ok
    else
      _failure -> {:error, :invalid_webhook_request}
    end
  rescue
    _error -> {:error, :invalid_webhook_request}
  catch
    _kind, _reason -> {:error, :invalid_webhook_request}
  end

  def validate_for_transport(_request, _settings), do: {:error, :invalid_webhook_request}

  defp exact_request?(request) do
    map_size(request) == @request_key_count and
      Enum.all?(@request_keys, &Map.has_key?(request, &1))
  end

  defp validate_payload(
         %{
           "allowed_mentions" => %{"parse" => []} = allowed_mentions,
           "content" => content,
           "username" => username
         } = payload
       ) do
    expected_size = if Map.has_key?(payload, "avatar_url"), do: 4, else: 3

    if map_size(payload) == expected_size and map_size(allowed_mentions) == 1 and
         MessageValidator.validate_content(content) == :ok and
         String.length(content) <= @max_content_characters and valid_username?(username) and
         valid_avatar_field?(payload) do
      :ok
    else
      {:error, :invalid_webhook_request}
    end
  end

  defp validate_payload(_payload), do: {:error, :invalid_webhook_request}

  defp valid_username?(value)
       when is_binary(value) and byte_size(value) in 1..@max_username_bytes do
    String.valid?(value) and String.trim(value) != "" and
      String.length(value) <= @max_username_characters
  end

  defp valid_username?(_value), do: false

  defp valid_avatar_field?(payload) do
    case Map.fetch(payload, "avatar_url") do
      :error -> true
      {:ok, value} -> valid_avatar_url?(value)
    end
  end

  defp valid_avatar_url?(value)
       when is_binary(value) and byte_size(value) <= @max_avatar_bytes do
    with true <- String.valid?(value),
         false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value),
         normalized when is_binary(normalized) <- :uri_string.normalize(value),
         {:ok, %URI{scheme: "https", host: host, userinfo: nil}} <- URI.new(normalized) do
      is_binary(host) and host != ""
    else
      _failure -> false
    end
  end

  defp valid_avatar_url?(_value), do: false

  defp encode_payload(payload) do
    body = %{
      "allowed_mentions" => %{"parse" => []},
      "content" => payload.content,
      "username" => payload.username
    }

    if payload.avatar_url == nil,
      do: body,
      else: Map.put(body, "avatar_url", payload.avatar_url)
  end
end

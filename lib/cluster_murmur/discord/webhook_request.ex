defmodule ClusterMurmur.Discord.WebhookRequest do
  @moduledoc """
  A fixed bounded request for one validated Discord webhook publication.

  The request always asks Discord for a response body, disables mention
  parsing, and carries fixed transport limits. Callers must revalidate the
  complete request against independent current inputs immediately before
  transport; the public struct is not itself an execution capability.
  """

  alias ClusterMurmur.Discord.PublicationPlanValidator
  alias ClusterMurmur.Discord.PublicationPlanner.Plan

  @content_type {"content-type", "application/json"}
  @wait_query {"wait", "true"}
  @connect_timeout_ms 5_000
  @receive_timeout_ms 10_000
  @overall_timeout_ms 15_000
  @max_response_bytes 16 * 1_024

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

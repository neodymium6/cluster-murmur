defmodule ClusterMurmur.Discord.WebhookHTTPTransportTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{
    WebhookHTTPResponseAccumulator,
    WebhookHTTPTransport,
    WebhookRequest,
    WebhookResponse,
    WebhookSettings
  }

  test "rejects forged requests without connecting" do
    settings = settings()
    request = request(settings)

    for candidate <- [
          %{request | url: "https://discord.com/api/webhooks/2/other-fake-token"},
          %{request | query: []},
          %{request | json: Map.put(request.json, "tts", true)},
          nil
        ] do
      assert WebhookHTTPTransport.execute(candidate, settings) ==
               {:error, :not_sent, :invalid_request}
    end

    assert WebhookHTTPTransport.execute(request, %WebhookSettings{url: "https://example.invalid"}) ==
             {:error, :not_sent, :invalid_request}
  end

  test "accumulates one bounded JSON success after informational responses" do
    reference = make_ref()
    state = %WebhookHTTPResponseAccumulator{}

    responses = [
      {:status, reference, 100},
      {:headers, reference, []},
      {:status, reference, 200},
      {:headers, reference, [{"content-type", "application/json; charset=utf-8"}]},
      {:data, reference, ~s({"id":"123"})},
      {:done, reference}
    ]

    assert WebhookHTTPResponseAccumulator.reduce(state, responses, reference, 16 * 1_024) ==
             {:done, {:ok, %WebhookResponse{status: 200, body: ~s({"id":"123"})}}}
  end

  test "requires exactly one JSON media type only for successful responses" do
    reference = make_ref()

    for headers <- [[], [{"content-type", "text/plain"}], duplicate_content_types()] do
      responses = [
        {:status, reference, 200},
        {:headers, reference, headers},
        {:data, reference, ~s({"id":"123"})},
        {:done, reference}
      ]

      assert WebhookHTTPResponseAccumulator.reduce(
               %WebhookHTTPResponseAccumulator{},
               responses,
               reference,
               16 * 1_024
             ) == {:done, {:error, :outcome_unknown}}
    end

    rejected = [
      {:status, reference, 401},
      {:headers, reference, [{"content-type", "text/plain"}]},
      {:data, reference, "private remote diagnostic"},
      {:done, reference}
    ]

    assert WebhookHTTPResponseAccumulator.reduce(
             %WebhookHTTPResponseAccumulator{},
             rejected,
             reference,
             16 * 1_024
           ) ==
             {:done, {:ok, %WebhookResponse{status: 401, body: "private remote diagnostic"}}}
  end

  test "classifies oversized and malformed post-dispatch responses as unknown" do
    reference = make_ref()
    other_reference = make_ref()
    state = %WebhookHTTPResponseAccumulator{}

    assert WebhookHTTPResponseAccumulator.reduce(
             state,
             [
               {:status, reference, 200},
               {:headers, reference, [{"content-type", "application/json"}]},
               {:data, reference, "12345"}
             ],
             reference,
             4
           ) == {:done, {:error, :outcome_unknown}}

    assert WebhookHTTPResponseAccumulator.reduce(
             state,
             [{:status, other_reference, 200}],
             reference,
             16 * 1_024
           ) == {:done, {:error, :outcome_unknown}}

    assert WebhookHTTPResponseAccumulator.reduce(
             state,
             [{:error, reference, :closed}],
             reference,
             16 * 1_024
           ) == {:done, {:error, :outcome_unknown}}
  end

  defp request(settings) do
    %WebhookRequest{
      method: :post,
      url: settings.url,
      headers: [{"content-type", "application/json"}],
      query: [{"wait", "true"}],
      json: %{
        "allowed_mentions" => %{"parse" => []},
        "content" => "A bounded example message.",
        "username" => "Example Observer"
      },
      connect_timeout_ms: 5_000,
      receive_timeout_ms: 10_000,
      overall_timeout_ms: 15_000,
      max_response_bytes: 16 * 1_024
    }
  end

  defp settings do
    %WebhookSettings{url: "https://discord.com/api/webhooks/1/clearly-fake-token"}
  end

  defp duplicate_content_types do
    [{"content-type", "application/json"}, {"Content-Type", "application/json"}]
  end
end

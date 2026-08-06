defmodule ClusterMurmur.Discord.WebhookResponseTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{WebhookRequest, WebhookResponse}

  test "extracts only one canonical message ID from a bounded success" do
    body =
      %{
        "id" => "12345",
        "channel_id" => "67890",
        "content" => "Approved but not returned."
      }
      |> :json.encode()
      |> IO.iodata_to_binary()

    assert WebhookResponse.decode(%WebhookResponse{status: 200, body: body}) ==
             {:ok, "12345"}
  end

  test "rejects malformed or noncanonical success bodies" do
    invalid_bodies = [
      "",
      "not-json",
      "{}",
      ~s({"id":null}),
      ~s({"id":12345}),
      ~s({"id":""}),
      ~s({"id":"0"}),
      ~s({"id":"012345"}),
      ~s({"id":"18446744073709551616"}),
      ~s({"id":"12345"} trailing),
      ~s({"id":"12345","id":"67890"})
    ]

    for body <- invalid_bodies do
      assert WebhookResponse.decode(%WebhookResponse{status: 200, body: body}) ==
               {:error, :invalid_response}
    end
  end

  test "classifies bounded Discord status families without decoding diagnostics" do
    cases = [
      {201, :invalid_response},
      {204, :invalid_response},
      {301, :invalid_response},
      {400, :invalid_request},
      {401, :authentication_failed},
      {403, :authentication_failed},
      {404, :authentication_failed},
      {408, :timeout},
      {409, :invalid_request},
      {429, :rate_limited},
      {500, :unavailable},
      {502, :unavailable},
      {504, :unavailable}
    ]

    for {status, error_class} <- cases do
      response = %WebhookResponse{status: status, body: <<255, 0, 1>>}
      assert WebhookResponse.decode(response) == {:error, error_class}
    end
  end

  test "rejects oversized or inexact response values before classification" do
    exact = %WebhookResponse{status: 429, body: String.duplicate("x", 16 * 1_024)}
    assert WebhookResponse.decode(exact) == {:error, :rate_limited}

    invalid = [
      nil,
      %{},
      %WebhookResponse{status: 99, body: ""},
      %WebhookResponse{status: 600, body: ""},
      %WebhookResponse{status: 200, body: String.duplicate("x", 16 * 1_024 + 1)},
      %WebhookResponse{status: 200, body: nil},
      Map.put(%WebhookResponse{status: 200, body: ~s({"id":"12345"})}, :private, true)
    ]

    for response <- invalid do
      assert WebhookResponse.decode(response) == {:error, :invalid_response}
    end

    assert WebhookRequest.max_response_bytes() == 16 * 1_024
  end

  test "inspection and errors never expose raw Discord response bodies" do
    body = ~s({"message":"Private Discord diagnostic","id":"not-an-id"})
    response = %WebhookResponse{status: 200, body: body}
    result = WebhookResponse.decode(response)

    assert result == {:error, :invalid_response}

    for inspected <- [inspect(response), inspect(result)] do
      refute inspected =~ "Private"
      refute inspected =~ "Discord diagnostic"
    end
  end
end

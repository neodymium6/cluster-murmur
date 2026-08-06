defmodule ClusterMurmur.Generation.OpenAICompatibleResponseTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Generation.{OpenAICompatibleRequest, OpenAICompatibleResponse}

  test "extracts only one bounded assistant message from a success" do
    body =
      %{
        "id" => "clearly-fake-completion-id",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "index" => 0,
            "message" => %{
              "content" => "The latest run completed.",
              "role" => "assistant"
            }
          }
        ],
        "usage" => %{"completion_tokens" => 6, "prompt_tokens" => 42}
      }
      |> :json.encode()
      |> IO.iodata_to_binary()

    assert OpenAICompatibleResponse.decode(%OpenAICompatibleResponse{status: 200, body: body}) ==
             {:ok, "The latest run completed."}
  end

  test "rejects malformed, duplicate-key, or unexpected success bodies" do
    invalid_bodies = [
      "",
      "not-json",
      "{}",
      ~s({"choices":null}),
      ~s({"choices":[]}),
      ~s({"choices":[{"message":null}]}),
      ~s({"choices":[{"message":{"content":null}}]}),
      ~s({"choices":[{"message":{"content":[{"type":"text","text":"value"}]}}]}),
      ~s({"choices":[{"message":{"content":"first"}},{"message":{"content":"second"}}]}),
      ~s({"choices":[{"message":{"content":"value","content":"forged"}}]}),
      ~s({"choices":[{"message":{"content":"value"}}]} trailing)
    ]

    for body <- invalid_bodies do
      assert OpenAICompatibleResponse.decode(%OpenAICompatibleResponse{status: 200, body: body}) ==
               {:error, :invalid_response}
    end
  end

  test "classifies status families without decoding provider diagnostics" do
    cases = [
      {201, :invalid_response},
      {204, :invalid_response},
      {301, :invalid_response},
      {400, :invalid_request},
      {401, :authentication_failed},
      {403, :authentication_failed},
      {404, :invalid_request},
      {408, :timeout},
      {422, :invalid_request},
      {429, :rate_limited},
      {500, :unavailable},
      {502, :unavailable},
      {504, :unavailable}
    ]

    for {status, error_class} <- cases do
      response = %OpenAICompatibleResponse{status: status, body: <<255, 0, 1>>}
      assert OpenAICompatibleResponse.decode(response) == {:error, error_class}
    end
  end

  test "rejects oversized or inexact response values before classification" do
    exact = %OpenAICompatibleResponse{
      status: 429,
      body: String.duplicate("x", OpenAICompatibleRequest.max_response_bytes())
    }

    assert OpenAICompatibleResponse.decode(exact) == {:error, :rate_limited}

    invalid = [
      nil,
      %{},
      %OpenAICompatibleResponse{status: 99, body: ""},
      %OpenAICompatibleResponse{status: 600, body: ""},
      %OpenAICompatibleResponse{
        status: 200,
        body: String.duplicate("x", OpenAICompatibleRequest.max_response_bytes() + 1)
      },
      %OpenAICompatibleResponse{status: 200, body: nil},
      Map.put(
        %OpenAICompatibleResponse{
          status: 200,
          body: ~s({"choices":[{"message":{"content":"value"}}]})
        },
        :private,
        true
      )
    ]

    for response <- invalid do
      assert OpenAICompatibleResponse.decode(response) == {:error, :invalid_response}
    end
  end

  test "inspection and errors never expose raw provider response bodies" do
    body =
      ~s({"error":{"message":"Private provider diagnostic"},"choices":[{"message":{"content":null}}]})

    response = %OpenAICompatibleResponse{status: 200, body: body}
    result = OpenAICompatibleResponse.decode(response)

    assert result == {:error, :invalid_response}

    for inspected <- [inspect(response), inspect(result)] do
      refute inspected =~ "Private"
      refute inspected =~ "provider diagnostic"
    end
  end
end

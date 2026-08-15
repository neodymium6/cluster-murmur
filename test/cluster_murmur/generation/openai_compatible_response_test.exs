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
        "usage" => %{
          "completion_tokens" => 6,
          "completion_tokens_details" => %{"reasoning_tokens" => 4},
          "prompt_tokens" => 42
        }
      }
      |> :json.encode()
      |> IO.iodata_to_binary()

    assert OpenAICompatibleResponse.decode(%OpenAICompatibleResponse{status: 200, body: body}) ==
             {:ok, "The latest run completed."}
  end

  test "classifies blank length completions as token exhaustion" do
    for content <- [:null, "", " \n\t"] do
      body =
        %{
          "choices" => [
            %{
              "finish_reason" => "length",
              "message" => %{"content" => content}
            }
          ],
          "usage" => %{
            "completion_tokens" => 4_096,
            "completion_tokens_details" => %{"reasoning_tokens" => 4_096}
          }
        }
        |> :json.encode()
        |> IO.iodata_to_binary()

      assert OpenAICompatibleResponse.decode(%OpenAICompatibleResponse{status: 200, body: body}) ==
               {:error, :token_exhausted}
    end
  end

  test "preserves partial length content and non-length blank content" do
    cases = [
      {"length", "Partial visible output.", {:ok, "Partial visible output."}},
      {"stop", "", {:ok, ""}},
      {"tool_calls", "Visible tool summary.", {:ok, "Visible tool summary."}},
      {"content_filter", "Visible safe output.", {:ok, "Visible safe output."}},
      {"function_call", "Visible legacy output.", {:ok, "Visible legacy output."}},
      {nil, "", {:ok, ""}}
    ]

    for {finish_reason, content, expected} <- cases do
      choice = %{"message" => %{"content" => content}}
      choice = if finish_reason, do: Map.put(choice, "finish_reason", finish_reason), else: choice
      body = :json.encode(%{"choices" => [choice]}) |> IO.iodata_to_binary()

      assert OpenAICompatibleResponse.decode(%OpenAICompatibleResponse{status: 200, body: body}) ==
               expected
    end
  end

  test "rejects malformed safe completion metadata" do
    valid_choice = %{
      "finish_reason" => "stop",
      "message" => %{"content" => "Visible output."}
    }

    invalid = [
      %{"choices" => [%{valid_choice | "finish_reason" => "private_reason"}]},
      %{"choices" => [%{valid_choice | "finish_reason" => 1}]},
      %{"choices" => [valid_choice], "usage" => "private usage"},
      %{"choices" => [valid_choice], "usage" => %{"completion_tokens" => -1}},
      %{"choices" => [valid_choice], "usage" => %{"completion_tokens" => 1.0}},
      %{
        "choices" => [valid_choice],
        "usage" => %{"completion_tokens" => 4, "completion_tokens_details" => "private"}
      },
      %{
        "choices" => [valid_choice],
        "usage" => %{
          "completion_tokens" => 4,
          "completion_tokens_details" => %{"reasoning_tokens" => -1}
        }
      },
      %{
        "choices" => [valid_choice],
        "usage" => %{
          "completion_tokens" => 4,
          "completion_tokens_details" => %{"reasoning_tokens" => 5}
        }
      }
    ]

    for decoded <- invalid do
      body = :json.encode(decoded) |> IO.iodata_to_binary()

      assert OpenAICompatibleResponse.decode(%OpenAICompatibleResponse{status: 200, body: body}) ==
               {:error, :invalid_response}
    end
  end

  test "accepts compatible responses that omit safe usage fields" do
    choices = [
      %{
        "finish_reason" => "stop",
        "message" => %{"content" => "Visible output."}
      }
    ]

    for usage <- [
          %{},
          %{"prompt_tokens" => 10},
          %{"completion_tokens_details" => %{"reasoning_tokens" => 4}}
        ] do
      body = :json.encode(%{"choices" => choices, "usage" => usage}) |> IO.iodata_to_binary()

      assert OpenAICompatibleResponse.decode(%OpenAICompatibleResponse{status: 200, body: body}) ==
               {:ok, "Visible output."}
    end
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

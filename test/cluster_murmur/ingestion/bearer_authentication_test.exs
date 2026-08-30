defmodule ClusterMurmur.Ingestion.BearerAuthenticationTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Ingestion.BearerAuthentication

  @token "abcdefghijklmnopqrstuvwxyzABCDEF123456"

  test "authorizes one exact bounded Bearer credential" do
    assert {:ok, digest} = BearerAuthentication.digest(@token)
    assert byte_size(digest) == 32
    assert BearerAuthentication.authorize("Bearer " <> @token, digest) == :ok
    assert BearerAuthentication.authorize("bearer " <> @token, digest) == :ok
    assert BearerAuthentication.authorize("BeArEr " <> @token, digest) == :ok

    assert BearerAuthentication.authorize(
             "Bearer abcdefghijklmnopqrstuvwxyzABCDEF654321",
             digest
           ) == {:error, :unauthorized}
  end

  test "rejects malformed tokens, schemes, headers, and digests" do
    invalid_tokens = [
      nil,
      "short",
      String.duplicate("x", 513),
      String.duplicate("x", 31) <> " ",
      String.duplicate("x", 32) <> "=middle",
      <<String.duplicate("x", 32)::binary, 255>>
    ]

    for token <- invalid_tokens do
      assert BearerAuthentication.digest(token) == {:error, :invalid_bearer_credential}
    end

    assert {:ok, digest} = BearerAuthentication.digest(@token)
    assert {:ok, padded_digest} = BearerAuthentication.digest(String.duplicate("x", 32) <> "===")

    assert BearerAuthentication.authorize(
             "Bearer " <> String.duplicate("x", 32) <> "===",
             padded_digest
           ) == :ok

    for header <- [nil, @token, "Basic " <> @token, "Bearer  " <> @token] do
      assert BearerAuthentication.authorize(header, digest) == {:error, :unauthorized}
    end

    assert BearerAuthentication.authorize("Bearer " <> @token, <<0>>) ==
             {:error, :unauthorized}
  end
end

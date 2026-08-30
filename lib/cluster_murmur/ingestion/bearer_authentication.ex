defmodule ClusterMurmur.Ingestion.BearerAuthentication do
  @moduledoc """
  Validates and compares one bounded HTTP Bearer credential.

  Settings retain only a SHA-256 digest. Presented credentials with a valid
  token68 shape are compared through fixed-length constant-time digests.
  """

  @max_token_bytes 512
  @min_token_bytes 32
  @digest_bytes 32
  @max_header_bytes @max_token_bytes + byte_size("Bearer ")
  @token_pattern ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  @type error :: :invalid_bearer_credential | :unauthorized

  @doc false
  @spec digest(term()) :: {:ok, binary()} | {:error, error()}
  def digest(token) do
    if valid_token?(token),
      do: {:ok, :crypto.hash(:sha256, token)},
      else: {:error, :invalid_bearer_credential}
  end

  @doc "Authorizes one exact Bearer header against a fixed-length digest."
  @spec authorize(term(), term()) :: :ok | {:error, error()}
  def authorize(authorization, expected_digest)
      when is_binary(authorization) and byte_size(authorization) <= @max_header_bytes and
             is_binary(expected_digest) and byte_size(expected_digest) == @digest_bytes do
    with [scheme, token] <- :binary.split(authorization, " ", [:global]),
         true <- byte_size(scheme) == 6 and String.downcase(scheme) == "bearer",
         {:ok, presented_digest} <- digest(token) do
      if :crypto.hash_equals(presented_digest, expected_digest),
        do: :ok,
        else: {:error, :unauthorized}
    else
      _failure -> {:error, :unauthorized}
    end
  rescue
    _error -> {:error, :unauthorized}
  catch
    _kind, _reason -> {:error, :unauthorized}
  end

  def authorize(_authorization, _expected_digest), do: {:error, :unauthorized}

  defp valid_token?(token)
       when is_binary(token) and byte_size(token) in @min_token_bytes..@max_token_bytes,
       do: String.valid?(token) and Regex.match?(@token_pattern, token)

  defp valid_token?(_token), do: false
end

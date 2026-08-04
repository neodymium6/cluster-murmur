defmodule ClusterMurmur.ExternalError do
  @moduledoc """
  Stable error classes returned across external dependency boundaries.

  Adapters may log sanitized diagnostic metadata internally, but raw provider
  errors, responses, endpoints, and secret values must not cross into domain
  or orchestration code.
  """

  @type t ::
          :authentication_failed
          | :invalid_request
          | :invalid_response
          | :rate_limited
          | :timeout
          | :unavailable
end

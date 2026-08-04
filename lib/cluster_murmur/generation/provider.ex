defmodule ClusterMurmur.Generation.Provider do
  @moduledoc """
  Boundary for generating an expression from application-supplied facts.

  Successful responses contain only normalized generated text. Raw provider
  payloads and errors do not cross this boundary.
  """

  alias ClusterMurmur.ExternalError

  @callback generate(map()) :: {:ok, String.t()} | {:error, ExternalError.t()}
end

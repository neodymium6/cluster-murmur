defmodule ClusterMurmur.Generation.Provider do
  @moduledoc """
  Boundary for generating an expression from application-supplied facts.

  Successful responses contain only normalized generated text. Raw provider
  payloads and errors do not cross this boundary. Implementations receive only
  the closed structured prompt capability and must reject forged or extended
  request values before making an external call.
  """

  alias ClusterMurmur.ExternalError
  alias ClusterMurmur.Generation.PromptRequest

  @callback generate(PromptRequest.t()) ::
              {:ok, String.t()} | {:error, ExternalError.t()}
end

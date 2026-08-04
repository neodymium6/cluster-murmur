defmodule ClusterMurmur.Generation.Provider do
  @moduledoc """
  Boundary for generating an expression from application-supplied facts.
  """

  @callback generate(map()) :: {:ok, map()} | {:error, term()}
end

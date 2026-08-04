defmodule ClusterMurmur.Random do
  @moduledoc """
  Random source used for policy decisions.

  Domain code computes and validates candidate weights. Implementations of
  this behaviour perform only the final sample.
  """

  @callback uniform() :: float()
  @callback weighted_choice([{term(), number()}]) :: {:ok, term()} | :empty
end

defmodule ClusterMurmur.Random do
  @moduledoc """
  Random source used for policy decisions.

  Domain code computes and validates candidate weights. Implementations of
  this behaviour perform only the final sample.

  `uniform/0` returns a finite value in the half-open interval `[0.0, 1.0)`.
  `weighted_choice/1` receives only finite, non-negative weights and returns
  `:empty` when the candidates are empty or their total weight is zero.
  """

  @callback uniform() :: float()
  @callback weighted_choice([{term(), number()}]) :: {:ok, term()} | :empty
end

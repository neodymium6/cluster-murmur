defmodule ClusterMurmur.Observers.Client do
  @moduledoc """
  Boundary for a normalized, read-only observation source.

  Concrete adapters map these named operations to their transport internally.
  No transport tool name, arbitrary argument map, or raw response crosses this
  boundary. Application code normalizes the returned target maps through the
  bounded target catalog before calling `observe_target/1`.
  """

  alias ClusterMurmur.ExternalError
  alias ClusterMurmur.Observations.Observation

  @type target :: %{required(:id) => String.t()}

  @callback list_targets() :: {:ok, [target()]} | {:error, ExternalError.t()}
  @callback observe_target(String.t()) ::
              {:ok, Observation.t()} | {:error, ExternalError.t()}
end

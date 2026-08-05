defmodule ClusterMurmur.Generation.PersonaProjection do
  @moduledoc """
  Exact persona identity and instructions allowed to cross the generation boundary.

  Selection identifiers, publication metadata, interests, behavior, and
  relationships are deliberately absent from this projection.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:display_name, :instructions]
  defstruct [:display_name, :instructions]

  @type t :: %__MODULE__{
          display_name: String.t(),
          instructions: String.t()
        }
end

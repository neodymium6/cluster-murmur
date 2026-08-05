defmodule ClusterMurmur.Personas.ResponderPolicy do
  @moduledoc """
  Immutable continuity policy for bounded responder eligibility.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:allow_same_persona_consecutively, :allow_persona_reentry]
  defstruct [:allow_same_persona_consecutively, :allow_persona_reentry]

  @type t :: %__MODULE__{
          allow_same_persona_consecutively: boolean(),
          allow_persona_reentry: boolean()
        }
end

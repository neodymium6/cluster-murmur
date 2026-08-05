defmodule ClusterMurmur.Personas.StarterCandidate do
  @moduledoc """
  Redacted, immutable projection of one eligible conversation starter.

  Selection randomness is deliberately absent. The projection preserves the
  bounded application-supplied weight components used by the later selector.
  """

  @derive {Inspect, only: []}
  @enforce_keys [
    :persona_id,
    :binding_weight,
    :interest_weight,
    :spontaneous_weight,
    :weight
  ]
  defstruct [
    :persona_id,
    :binding_weight,
    :interest_weight,
    :spontaneous_weight,
    :weight
  ]

  @type t :: %__MODULE__{
          persona_id: String.t(),
          binding_weight: number(),
          interest_weight: number(),
          spontaneous_weight: number(),
          weight: number()
        }
end

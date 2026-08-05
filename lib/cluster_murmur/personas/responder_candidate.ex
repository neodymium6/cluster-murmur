defmodule ClusterMurmur.Personas.ResponderCandidate do
  @moduledoc """
  Redacted configured-weight projection of one eligible responder.
  """

  @derive {Inspect, only: []}
  @enforce_keys [
    :persona_id,
    :binding_weight,
    :interest_weight,
    :relationship_weight,
    :reply_weight,
    :weight
  ]
  defstruct [
    :persona_id,
    :binding_weight,
    :interest_weight,
    :relationship_weight,
    :reply_weight,
    :weight
  ]

  @type t :: %__MODULE__{
          persona_id: String.t(),
          binding_weight: number(),
          interest_weight: number(),
          relationship_weight: number(),
          reply_weight: number(),
          weight: number()
        }
end

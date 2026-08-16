defmodule ClusterMurmur.Generation.Context do
  @moduledoc """
  Exact separated inputs for one bounded generation request.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:persona, :facts, :creative_context, :conversation]
  defstruct [:persona, :facts, :creative_context, :conversation]

  @type t :: %__MODULE__{
          persona: ClusterMurmur.Generation.PersonaProjection.t(),
          facts: ClusterMurmur.Generation.FactProjection.t() | nil,
          creative_context: ClusterMurmur.Generation.CreativeContext.t(),
          conversation: [ClusterMurmur.Generation.ConversationLine.t()]
        }
end

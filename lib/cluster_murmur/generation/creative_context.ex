defmodule ClusterMurmur.Generation.CreativeContext do
  @moduledoc """
  Bounded application-supplied creative framing for one generation request.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:conversation_kind, :mood]
  defstruct [:conversation_kind, :mood]

  @type t :: %__MODULE__{conversation_kind: String.t(), mood: String.t()}
end

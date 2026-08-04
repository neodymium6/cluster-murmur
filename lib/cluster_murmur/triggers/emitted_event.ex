defmodule ClusterMurmur.Triggers.EmittedEvent do
  @moduledoc """
  A validated event emitted by an application-owned trigger.

  The value contains only bounded identifiers. Its group reference remains
  unresolved until complete configuration assembly.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:type, :group, :subject]
  defstruct [:type, :group, :subject]

  @type t :: %__MODULE__{
          type: String.t(),
          group: String.t(),
          subject: String.t()
        }
end

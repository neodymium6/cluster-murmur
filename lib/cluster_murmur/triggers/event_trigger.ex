defmodule ClusterMurmur.Triggers.EventTrigger do
  @moduledoc """
  A validated event trigger that starts a bounded conversation.

  Binding references remain unresolved until complete configuration assembly.
  Matcher evaluation and action execution are deterministic application logic.
  """

  alias ClusterMurmur.Events.Matcher

  @derive {Inspect, only: []}
  @enforce_keys [:id, :matcher, :action, :binding, :cooldown_ms]
  defstruct [:id, :matcher, :action, :binding, :cooldown_ms]

  @type t :: %__MODULE__{
          id: String.t(),
          matcher: Matcher.t(),
          action: :start_conversation,
          binding: String.t(),
          cooldown_ms: non_neg_integer()
        }
end

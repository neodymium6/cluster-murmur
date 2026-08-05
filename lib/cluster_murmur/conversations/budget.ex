defmodule ClusterMurmur.Conversations.Budget do
  @moduledoc """
  Immutable configured limits for one bounded conversation.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:max_turns, :max_participants, :max_duration_ms, :max_llm_calls]
  defstruct [:max_turns, :max_participants, :max_duration_ms, :max_llm_calls]

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_participants: pos_integer(),
          max_duration_ms: pos_integer(),
          max_llm_calls: pos_integer()
        }
end

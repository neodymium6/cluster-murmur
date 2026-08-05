defmodule ClusterMurmur.Conversations.BudgetState do
  @moduledoc """
  Redacted projection of remaining conversation capacity at one supplied time.
  """

  @derive {Inspect, only: [:open?, :exhausted]}
  @enforce_keys [
    :open?,
    :exhausted,
    :turns_remaining,
    :participant_slots_remaining,
    :duration_remaining_ms,
    :llm_calls_remaining
  ]
  defstruct [
    :open?,
    :exhausted,
    :turns_remaining,
    :participant_slots_remaining,
    :duration_remaining_ms,
    :llm_calls_remaining
  ]

  @type exhausted_reason :: :duration | :llm_calls | :participants | :terminal | :turns
  @type t :: %__MODULE__{
          open?: boolean(),
          exhausted: [exhausted_reason()],
          turns_remaining: non_neg_integer(),
          participant_slots_remaining: non_neg_integer(),
          duration_remaining_ms: non_neg_integer(),
          llm_calls_remaining: non_neg_integer()
        }
end

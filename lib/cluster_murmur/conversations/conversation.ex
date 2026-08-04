defmodule ClusterMurmur.Conversations.Conversation do
  @moduledoc """
  Bounded state for one short conversation.
  """

  @derive {Inspect, only: [:status, :turn_count, :llm_call_count]}
  defstruct [
    :id,
    :root_event_id,
    :status,
    :started_at,
    :last_message_at,
    :turn_count,
    :llm_call_count,
    participants: [],
    messages: []
  ]

  @type status :: :starting | :generating | :waiting | :completed | :cancelled | :failed

  @type t :: %__MODULE__{
          id: String.t() | nil,
          root_event_id: String.t() | nil,
          status: status() | nil,
          started_at: DateTime.t() | nil,
          last_message_at: DateTime.t() | nil,
          turn_count: non_neg_integer() | nil,
          llm_call_count: non_neg_integer() | nil,
          participants: [String.t()],
          messages: [term()]
        }
end

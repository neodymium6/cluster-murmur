defmodule ClusterMurmur.Persistence.EventDispatchCandidate do
  @moduledoc "A redacted available outbox projection without claim material."

  @derive {Inspect, only: []}
  @enforce_keys [:event_id, :enqueued_at]
  defstruct [:event_id, :enqueued_at]

  @type t :: %__MODULE__{event_id: String.t(), enqueued_at: DateTime.t()}
end

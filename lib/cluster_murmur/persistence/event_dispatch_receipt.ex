defmodule ClusterMurmur.Persistence.EventDispatchReceipt do
  @moduledoc "A redacted claim-free receipt for one durable outbox entry."

  @derive {Inspect, only: [:status]}
  @enforce_keys [:event_id, :status, :enqueued_at]
  defstruct [:event_id, :status, :enqueued_at]

  @type t :: %__MODULE__{
          event_id: String.t(),
          status: ClusterMurmur.Persistence.EventDispatch.status(),
          enqueued_at: DateTime.t()
        }
end

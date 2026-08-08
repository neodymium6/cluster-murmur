defmodule ClusterMurmur.Persistence.EventDispatchClaim do
  @moduledoc "An opaque fixed lease authorizing one outbox completion."

  @derive {Inspect, only: []}
  @enforce_keys [:event_id, :enqueued_at, :token, :started_at, :expires_at]
  defstruct [:event_id, :enqueued_at, :token, :started_at, :expires_at]

  @type t :: %__MODULE__{
          event_id: String.t(),
          enqueued_at: DateTime.t(),
          token: String.t(),
          started_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end

defmodule ClusterMurmur.Persistence.StochasticScheduleClaim do
  @moduledoc """
  Opaque bounded lease authorizing one stochastic schedule execution attempt.

  Every field is redacted from inspection because the token is a capability and
  the schedule identifiers and timestamps may reveal deployment activity.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:trigger_id, :expected_next_run_at, :token, :started_at, :expires_at]
  defstruct [:trigger_id, :expected_next_run_at, :token, :started_at, :expires_at]

  @type t :: %__MODULE__{
          trigger_id: String.t(),
          expected_next_run_at: DateTime.t(),
          token: String.t(),
          started_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end

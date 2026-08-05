defmodule ClusterMurmur.Conversations.ReplyGateDecision do
  @moduledoc """
  Explicit redacted outcome of one event-group reply-probability gate.
  """

  @derive {Inspect, only: [:outcome]}
  @enforce_keys [:outcome]
  defstruct [:outcome]

  @type outcome :: :reply | :no_reply
  @type t :: %__MODULE__{outcome: outcome()}
end

defmodule ClusterMurmur.Conversations.ResponderContinuationConsumer do
  @moduledoc """
  Narrow synchronous boundary for one responder continuation selection.

  Implementations preflight all context before randomness is consumed, then
  atomically consume the plan's durable responder claim before any effect. The
  dispatcher creates that exact persona-bound claim before handoff.
  """

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.{Input, Plan}

  @callback preflight(Input.t(), term()) :: :ok | {:error, atom()}
  @callback consume(Plan.t(), term()) :: :ok | {:error, atom()}
end

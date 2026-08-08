defmodule ClusterMurmur.Conversations.ResponderContinuationConsumer do
  @moduledoc """
  Narrow synchronous boundary for one responder continuation selection.

  Implementations preflight all context before randomness is consumed, then
  consume exactly one selected reply or no-reply plan after the dispatcher has
  authoritatively claimed its waiting conversation for generation.
  """

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.{Input, Plan}

  @callback preflight(Input.t(), term()) :: :ok | {:error, atom()}
  @callback consume(Plan.t(), term()) :: :ok | {:error, atom()}
end

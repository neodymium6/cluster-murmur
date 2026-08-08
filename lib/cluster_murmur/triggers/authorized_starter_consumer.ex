defmodule ClusterMurmur.Triggers.AuthorizedStarterConsumer do
  @moduledoc """
  Narrow synchronous consumer for one newly authorized starter action.

  The consumer first validates its complete batch context before authorization.
  It then receives each exact redacted authorization and stable position in the
  bounded poll plan. Implementations must attempt that starter action once and
  return no reusable authorization capability.
  """

  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization

  @callback preflight(
              ClusterMurmur.Triggers.PollEventTriggerPlanner.Plan.t(),
              ClusterMurmur.Observers.Poller.Result.t(),
              ClusterMurmur.Config.Configuration.t(),
              term()
            ) :: :ok | {:error, atom()}
  @callback consume(Authorization.t(), non_neg_integer(), term()) :: :ok | {:error, atom()}
end

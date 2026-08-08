defmodule ClusterMurmur.Runtime.SystemClock do
  @moduledoc "The production UTC clock implementation."

  @behaviour ClusterMurmur.Runtime.Clock

  @impl true
  def utc_now, do: DateTime.utc_now()
end

defmodule ClusterMurmur.Discord.Publisher do
  @moduledoc """
  Boundary for outbound Discord publication.

  Implementations receive a bounded message payload and must not expose the
  configured webhook URL through return values or logs.
  """

  @callback publish(map()) :: {:ok, map()} | {:error, term()}
end

defmodule ClusterMurmur do
  @moduledoc """
  Event-driven orchestration for short, persona-based cluster conversations.
  """

  @version Mix.Project.config()[:version]

  @doc "Returns the application version."
  @spec version() :: String.t()
  def version, do: @version
end

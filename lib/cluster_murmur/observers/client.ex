defmodule ClusterMurmur.Observers.Client do
  @moduledoc """
  Boundary for a normalized, read-only observation source.

  Callers must choose tool names and validate their arguments in application
  code. This callback is not a generic MCP passthrough capability.
  """

  @callback list_targets() :: {:ok, map()} | {:error, term()}
  @callback call_tool(String.t(), map()) :: {:ok, map()} | {:error, term()}
end

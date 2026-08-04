defmodule ClusterMurmur.CLI do
  @moduledoc false

  @spec main([String.t()]) :: :ok | no_return()
  def main(["--version"]) do
    IO.puts(ClusterMurmur.version())
  end

  def main(_args) do
    IO.puts(:stderr, "Usage: cluster-murmur --version")
    System.halt(64)
  end
end

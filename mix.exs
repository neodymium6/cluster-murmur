defmodule ClusterMurmur.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :cluster_murmur,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: ClusterMurmur.CLI, name: "cluster-murmur"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ClusterMurmur.Application, []}
    ]
  end

  defp deps, do: []
end

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
      escript: [main_module: ClusterMurmur.CLI, name: "cluster-murmur", app: nil],
      releases: [cluster_murmur: []]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ClusterMurmur.Application, []}
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:crontab, "~> 1.2"},
      {:ecto_sqlite3, "~> 0.24.1"},
      {:ex_json_schema, "~> 0.11.4"},
      {:time_zone_info, "~> 0.7"},
      {:yamerl, "~> 0.10.0"}
    ]
  end
end

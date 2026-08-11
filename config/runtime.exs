import Config

database_path =
  case config_env() do
    :test ->
      ":memory:"

    :prod ->
      System.get_env("CLUSTER_MURMUR_DATABASE_PATH") ||
        raise "CLUSTER_MURMUR_DATABASE_PATH must be set in production"

    _environment ->
      System.get_env("CLUSTER_MURMUR_DATABASE_PATH") ||
        Path.expand("../.local/cluster-murmur.sqlite3", __DIR__)
  end

allow_in_memory? = config_env() == :test

valid_database_path? =
  if allow_in_memory? do
    database_path == ":memory:"
  else
    is_binary(database_path) and byte_size(database_path) in 1..4_096 and
      String.valid?(database_path) and not String.contains?(database_path, <<0>>) and
      Path.type(database_path) == :absolute
  end

unless valid_database_path? do
  raise "CLUSTER_MURMUR_DATABASE_PATH must be an absolute path"
end

config :cluster_murmur, ClusterMurmur.Repo,
  database: database_path,
  allow_in_memory: allow_in_memory?

config :cluster_murmur,
  standalone_runtime: config_env() == :prod

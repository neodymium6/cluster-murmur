import Config

# Release builds use an embedded IANA database snapshot. Configuration
# validation must never initiate network traffic to update it at runtime.
config :elixir, :time_zone_database, TimeZoneInfo.TimeZoneDatabase
config :time_zone_info, update: :disabled

config :cluster_murmur,
  ecto_repos: [ClusterMurmur.Repo]

config :cluster_murmur, ClusterMurmur.Repo,
  pool_size: 1,
  default_transaction_mode: :immediate,
  busy_timeout: 5_000,
  journal_mode: :wal,
  temp_store: :memory,
  foreign_keys: :on,
  log: false,
  stacktrace: false,
  show_sensitive_data_on_connection_error: false

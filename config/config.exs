import Config

# Release builds use an embedded IANA database snapshot. Configuration
# validation must never initiate network traffic to update it at runtime.
config :elixir, :time_zone_database, TimeZoneInfo.TimeZoneDatabase
config :time_zone_info, update: :disabled

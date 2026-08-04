Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260804130000_create_stochastic_schedules.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260804160000_add_stochastic_schedule_claims.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260804180500_create_events.exs",
    __DIR__
  )
)

ExUnit.start()

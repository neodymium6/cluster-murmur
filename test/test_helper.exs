Code.require_file(Path.expand("support/private_tmp_dir.exs", __DIR__))
Code.require_file(Path.expand("support/runtime_fixture.exs", __DIR__))

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

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260804200000_create_trigger_executions.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805200000_create_conversations.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805210000_add_incomplete_conversation_index.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805220000_create_messages.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805223000_add_persona_message_history_index.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805224000_create_persona_cooldowns.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805225000_create_entity_states.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805230000_create_publication_attempts.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260805231000_add_publication_attempt_dispatching.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260808060000_create_responder_generation_claims.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260808150000_create_event_dispatches.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260809020000_create_event_dedupe_markers.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260809043000_add_event_dedupe_marker_prune_index.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260809050000_add_event_retention_lookup_indexes.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand(
    "../priv/repo/migrations/20260809051500_create_event_retention_sweeps.exs",
    __DIR__
  )
)

Code.require_file(
  Path.expand("../priv/repo/migrations/20260809062000_create_schedule_states.exs", __DIR__)
)

ExUnit.start()

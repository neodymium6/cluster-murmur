[
  # External library return types are narrower than the fail-closed runtime checks.
  {"lib/cluster_murmur/config/configuration_validator.ex", :pattern_match_cov, {248, 7}},
  {"lib/cluster_murmur/config/triggers.ex", :pattern_match_cov, {211, 7}},
  {"lib/cluster_murmur/config/triggers.ex", :pattern_match_cov, {493, 7}},
  {"lib/cluster_murmur/release.ex", :pattern_match_cov, {165, 7}},

  # Exact runtime representation checks reject forged structs with extra keys.
  {"lib/cluster_murmur/generation/openai_compatible_request.ex", :pattern_match, 1},

  # Injected observer and persistence boundaries reject undocumented outcomes.
  {"lib/cluster_murmur/observers/poller.ex", :pattern_match_cov, {100, 7}},
  {"lib/cluster_murmur/persistence/event_trigger_conversation_action_store.ex",
   :pattern_match_cov, {77, 7}},
  {"lib/cluster_murmur/persistence/observation_ingestion_store.ex", :pattern_match_cov, {67, 7}},

  # Public orchestration boundaries normalize unexpected nested or adapter results.
  {"lib/cluster_murmur/runtime/responder_conversation_runner.ex", :pattern_match_cov, {144, 7}},
  {"lib/cluster_murmur/runtime/responder_turn_cycle.ex", :pattern_match_cov, {131, 7}},
  {"lib/cluster_murmur/runtime/responder_turn_cycle.ex", :pattern_match_cov, {210, 7}},
  {"lib/cluster_murmur/runtime/responder_turn_cycle.ex", :pattern_match_cov, {225, 7}},
  {"lib/cluster_murmur/triggers/authorized_starter_pipeline.ex", :pattern_match_cov, {253, 7}},
  {"lib/cluster_murmur/triggers/authorized_starter_pipeline.ex", :pattern_match_cov, {340, 7}},
  {"lib/cluster_murmur/triggers/event_dispatch_planner.ex", :pattern_match_cov, {89, 7}},
  {"lib/cluster_murmur/triggers/event_dispatch_planner.ex", :pattern_match_cov, {184, 7}},
  {"lib/cluster_murmur/triggers/event_trigger_batch_authorizer.ex", :pattern_match_cov, {108, 7}},
  {"lib/cluster_murmur/triggers/event_trigger_conversation_planner.ex", :pattern_match_cov,
   {73, 7}},
  {"lib/cluster_murmur/triggers/poll_event_trigger_planner.ex", :pattern_match_cov, {94, 7}}
]

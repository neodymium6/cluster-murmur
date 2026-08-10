# Dialyzer boundary filters

## Policy

The Dialyzer baseline is not a general warning waiver. Every entry in
`.dialyzer_ignore.exs` identifies one exact warning location where application
code deliberately handles a runtime value outside a dependency, behaviour, or
internal success type. These clauses fail closed instead of accepting or
propagating an undocumented value.

Dialyxir runs with `list_unused_filters: true`, so a filter that no longer
matches fails the repository check. New warnings must be fixed unless a review
establishes a concrete boundary reason and records it here. Broad file, module,
or warning-class filters are not permitted.

## Retained boundaries

### External library contracts

- `ConfigurationValidator.load_timezones/0` and `Triggers.load_timezones/0`
  reject a non-list timezone catalog before it reaches configuration state.
- `Triggers.parse_cron/1` rejects any result outside the documented successful
  and error tuples from the cron parser.
- `Release.packaged_migration_result/0` converts any non-list migration result
  into the stable redacted `:migration_failed` release error.

Dialyzer sees the pinned libraries' current return types and therefore regards
these fallbacks as unreachable. They remain at the library boundary so a
dependency regression cannot silently cross into application state.

### Exact runtime representations

- `OpenAICompatibleRequest.validate_prompt/1` rejects a forged
  `PromptRequest` map containing keys outside the exact struct definition.

Elixir struct types describe the declared fields, while a runtime map can be
forged with the same `__struct__` tag and additional keys. The exact-key check
protects the final provider-request encoding boundary.

### Injected observer and persistence results

- `Poller.poll_once/3` rejects undocumented observer or ingestion-store
  results.
- `EventTriggerConversationActionStore.consume_transaction/1` rolls back an
  undocumented nested store result.
- `ObservationIngestionStore.transact/2` rolls back an undocumented planner or
  nested store result.

These modules call injected behaviours or execute multi-step storage work. A
declared success type does not replace runtime validation at that boundary.

### Public orchestration results

- `ResponderConversationRunner.run_turns/4` rejects a turn-cycle result outside
  its bounded terminal, continuation, failure, ambiguity, and error variants.
- `ResponderTurnCycle.run/2`, `continue_selected/3`, and `finish/5` reject
  undocumented planner, adapter, publication, cooldown, or finisher outcomes.
- `AuthorizedStarterPipeline.run/2` and `finish/3` reject undocumented starter
  pipeline or finisher outcomes.
- `EventDispatchPlanner.plan/4` and `build_entries/9` reject undocumented nested
  validation or selection outcomes.
- `EventTriggerBatchAuthorizer.authorize_matching/4` rejects undocumented
  selector or injected authorizer outcomes.
- `EventTriggerConversationPlanner.plan/5` rejects undocumented validation,
  resolution, or injected-random outcomes.
- `PollEventTriggerPlanner.plan/3` rejects undocumented nested validation or
  selection outcomes.

These functions are callable orchestration boundaries that accept runtime data
or invoke injected modules. Their catch-all clauses normalize contract drift to
stable application errors and never turn an unknown result into an action.

## Removed filters

During the public alpha audit, three catch-all clauses were removed from
`ConfigurationValidator.exact_keys?/2`,
`EventDispatchStore.valid_candidate_shape?/1`, and
`RecurringScheduleInitializer.calculate_versions/3`. All their callers already
establish the required map, struct, or proper-list shape, and their enclosing
public boundaries still catch exceptions and fail closed. Keeping those clauses
would only hide unreachable internal branches rather than protect a runtime
boundary.

# Isolated end-to-end example

This executable example is the focused integration test at
`test/cluster_murmur/runtime/isolated_end_to_end_test.exs`. It uses only loopback
listeners, clearly fake credentials, and an in-process publication sink. It
does not connect to infrastructure, a model provider, GHCR, or Discord.

Run it from the repository development shell:

```bash
mix test test/cluster_murmur/runtime/isolated_end_to_end_test.exs
```

The example exercises these boundaries in order:

1. a minimal HTTP MCP service returns one fixed Kubernetes cluster-health
   target and one normalized degraded observation;
2. the real bounded observer HTTP transport decodes that observation;
3. the real SQLite ingestion store commits the entity state and transition
   event atomically;
4. application code matches and authorizes the configured trigger;
5. a loopback OpenAI-compatible service receives the real bounded request and
   returns one bounded generated message;
6. the real conversation and publication lifecycle stores persist the message
   and one successful publication attempt;
7. the real webhook publisher validates the complete Discord request, while an
   in-process destination records it without invoking the production transport;
8. startup recovery observes no abandoned work; and
9. a resumed poll advances the durable observation timestamp without creating
   or publishing a duplicate transition.

The final destination is injected deliberately. The production Discord
transport is pinned to authenticated HTTPS at `discord.com` and must not gain a
test-controlled authority or generic HTTP escape hatch. This example therefore
tests the complete fixed Discord request and publication lifecycle while
keeping the external effect process-local.

The example asserts one event, conversation, generated message, publication
attempt, and destination delivery. It also asserts the second observation is
persisted, no second event or model request occurs, completed work is not
changed by startup recovery, and aggregate results do not expose supplied
facts or generated content.

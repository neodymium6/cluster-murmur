# Cluster Murmur v0.1.0-alpha.1

This is the first public alpha of the Cluster Murmur engine. It packages the
environment-neutral, opt-in observation-to-conversation core and its bounded
runtime components. It is a prerelease for evaluation and integration work, not
a supported standalone service or a live deployment.

## Highlights

- Strict, bounded version 1 configuration loading and startup preparation.
- Deterministic observation ingestion, debounce, event extraction, dedupe, and
  event-trigger planning.
- Durable SQLite lifecycles for events, trigger executions, conversations,
  generated messages, cooldowns, dispatches, schedules, publication attempts,
  recovery, and retention cursors.
- Bounded starter and responder orchestration with explicit no-reply paths,
  hard turn, participant, duration, LLM-call, cooldown, and scheduling limits.
- Fixed OpenAI-compatible generation and Discord publication boundaries with
  allowlisted facts, safe output normalization, deterministic fallback text,
  disabled mentions, and ambiguous-effect handling without implicit retries.
- Opt-in schedulers and supervisors with restart recovery and no live defaults.
- Nondistributed OTP release and hardened OCI image packaging.

## Verification

Repository CI runs the complete locked-dependency audit, formatting,
warnings-as-errors compilation, Credo, Dialyzer, tests, repository metadata,
production-release, and container-image checks. The artifact checks cover
packaged migrations, isolated SQLite storage, start and stop behavior, disabled
distribution, redacted failures, OCI metadata, runtime-closure completeness,
read-only-compatible paths, and an extracted Tini/release smoke test.

Build the source revision's release from the pinned Nix inputs:

```bash
nix build .#cluster-murmur
```

On Linux, build the container archive with:

```bash
nix build .#container-image
```

No credentials, deployment configuration, or live endpoints are included.

## Integration boundary

`ClusterMurmur.Application` intentionally starts only the SQLite repository. An
integrator must explicitly assemble the reviewed opt-in supervisors and workers
with a configuration, clock, random source, stores, and narrow transports.

Live MCP, model-provider, and Discord transports; concrete endpoints and
routing; mounted credentials; health integration; deployment manifests;
production telemetry; and rollout policy remain deployment-owned. Do not run
this prerelease against production, sensitive systems, model providers, or
Discord without an explicit review of that exact private assembly.

Retention remains conservative: the engine may prune bounded dedupe state and
events with no lifecycle references, but it does not cascade through referenced
trigger executions, conversations, dispatches, or dedupe markers.

See [the public alpha boundary](https://github.com/neodymium6/cluster-murmur/blob/v0.1.0-alpha.1/docs/public-alpha.md),
[the configuration reference](https://github.com/neodymium6/cluster-murmur/blob/v0.1.0-alpha.1/docs/configuration.md),
and [the security policy](https://github.com/neodymium6/cluster-murmur/blob/v0.1.0-alpha.1/SECURITY.md)
before integration.

# Public alpha boundary

## Purpose

The public alpha is an environment-neutral, composable engine. It proves the
bounded observation-to-conversation behavior without choosing a live
deployment, embedding credentials, or connecting to external infrastructure.

The alpha is not a standalone service. `ClusterMurmur.Application` starts only
the SQLite repository. A deployment that enables runtime work must explicitly
assemble the reviewed opt-in supervisors and workers with their configuration,
clock, random source, stores, and narrow transports.

## Included

The public alpha includes:

- strict public configuration loading and startup input preparation;
- bounded observation, event, trigger, conversation, generation, publication,
  recovery, scheduling, and retention components;
- exact SQLite persistence and packaged migrations;
- opt-in poll, event-dispatch, stochastic, recurring, and retention workers;
- deterministic fallback generation and stable external error classes;
- fake-adapter integration and restart coverage;
- nondistributed OTP release and hardened OCI image packaging; and
- formatting, compilation, tests, Credo, Dialyzer, repository metadata, release,
  and container checks.

## Deployment-owned inputs

The public repository deliberately does not provide live defaults. A private
deployment owns:

- concrete configuration paths, endpoints, and routing;
- mounted credentials and secret-file locations;
- fixed MCP, model-provider, and Discord transport implementations;
- the production random source and clock;
- construction and supervision of the opt-in runtime; and
- platform-specific storage, network policy, health integration, and rollout
  policy.

These inputs must use the narrow public behaviours and must not add generic
shell, SSH, `kubectl`, SQL, PromQL, or arbitrary HTTP passthrough capabilities.

## Retention boundary

Alpha retention is conservative. The engine may prune bounded dedupe state and
events that have no references from trigger executions, conversations,
dispatches, or dedupe markers. It does not cascade through referenced lifecycle
data. A broader deletion policy requires explicit retention periods, ordering,
and recovery semantics in a later architecture decision.

## Completion criteria

The public alpha is ready when:

1. all repository checks pass without live infrastructure;
2. dependency retirement and vulnerability checks are reproducible in CI;
3. every Dialyzer baseline entry is exact, current, and retained for a
   [documented fail-closed boundary](dialyzer-boundaries.md) rather than
   convenience;
4. the production release starts, stops, and migrates an isolated temporary
   database without distribution or credentials;
5. the OCI image has the documented non-root, read-only-compatible metadata,
   contains its runtime closure, and its extracted entrypoint passes a smoke
   test against isolated temporary storage; and
6. README, design, security, and configuration documentation agree on the
   public/private boundary.

## Readiness evidence

The public alpha engine satisfies these criteria through repository-owned,
environment-neutral checks:

- `just check` runs the dependency audit, formatting, warnings-as-errors
  compilation, Credo, Dialyzer, tests, and every Nix check without live
  infrastructure.
- `mix hex.audit` checks the complete locked dependency graph for retirements
  and published security advisories before the remaining checks.
- Dialyxir rejects both new warnings and unused exact filters; every retained
  filter has a concrete rationale in
  [`dialyzer-boundaries.md`](dialyzer-boundaries.md).
- the production-release Nix check verifies packaged migrations, isolated
  database permissions, start and stop behavior, redacted migration failure,
  and disabled distribution;
- the container-image Nix check verifies OCI metadata, runtime-closure
  completeness, read-only-compatible paths, an isolated migration, and
  extracted Tini/release start and stop behavior; and
- the status and boundary language in README, design, security, configuration,
  and the MVP contract distinguishes this engine from the deferred standalone
  service.

This readiness statement does not authorize a deployment or connection to live
infrastructure. The deployment-owned inputs and deferred work below still
apply.

## Deferred standalone-service work

Live transports, automatic runtime assembly, health endpoints, deployment
manifests, production metrics and structured logging, and referenced-lifecycle
retention remain outside the public alpha. Discord mention handling and bounded
question-scoped tools remain post-MVP extensions.

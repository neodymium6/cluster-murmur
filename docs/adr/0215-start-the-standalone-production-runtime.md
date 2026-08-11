# 0215. Start the standalone production runtime

Date: 2026-08-11

## Status

Accepted

## Context

The application has fixed, validated production transports, conversation
adapters, scheduler options, recovery, and schedule initialization, but its OTP
entry point still starts only the repository. A release therefore cannot run
the implemented observation-to-conversation loop without deployment-owned
Elixir assembly. Starting that loop in every Mix environment would make tests
and embedded development depend on production configuration and secret files.

## Decision

Enable standalone runtime assembly only when the application is built in the
production environment. Production startup reads one bounded absolute
`CLUSTER_MURMUR_CONFIG_PATH`, prepares all configuration and deployment
settings, constructs the exact recovery-gated supervisor options, and returns
the repository followed by that supervisor as one ordered child list.

Keep child-list construction independently callable and effect-bounded. It may
read configuration and mounted secret files, but it does not read a clock,
recover persistence, start workers, or contact external services. The OTP root
uses a rest-for-one strategy and starts the repository first; starting the
second child then performs recovery and both schedule initializations before
any of the five schedulers. A repository restart therefore stops the dependent
runtime and reruns those gates only after repository replacement. Any invalid
path, setting, option correlation, recovery, or initialization fails startup
with a stable value-free error.

Development and test builds retain the repository-only application. This keeps
library and integration use explicit without weakening the production release
entry point.

## Consequences

The shipped production release is now a complete standalone runtime once an
operator supplies reviewed configuration, mounted secrets, migrated storage,
and the required fixed environment values. It remains nondistributed and does
not gain generic transport, command, query, or remediation capabilities.

Startup is intentionally fail-closed and may stop after the repository has
briefly started; normal OTP supervisor startup cleanup terminates already
started children. Live deployment and rollout still require explicit approval
for the exact environment and revision.

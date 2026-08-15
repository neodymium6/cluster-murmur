# Security Policy

## Supported versions

There are no production-supported releases yet. Source version
`0.2.0-alpha.8` is the current standalone alpha and contains the fixed
production entry point. Alpha status does not authorize connecting any revision
to production or sensitive systems without review and explicit approval for the
exact deployment.

## Security boundary

Cluster Murmur consumes bounded, read-only observations and publishes generated
messages. It does not own infrastructure credentials, raw infrastructure APIs,
probe execution, mutation, remediation, or unrestricted tool use.

Factual decisions such as failure, recovery, severity, and state transitions
must be made by deterministic application code. LLMs may only turn supplied
facts into persona-specific language. Tool access must remain disabled by
default and, if introduced later, must use application-enforced allowlists and
strict call, round, timeout, and concurrency limits.

## Dependency auditing

`mix.lock` fixes the complete Hex dependency graph and `flake.lock` fixes the
development and CI toolchain. `just audit` runs `mix hex.audit`, which fails for
any locked package version that Hex reports as retired or affected by a
published security advisory. `just check` and CI run this audit before the
remaining repository checks.

There are no ignored advisories or retirements. Any future exception must name
one exact advisory or package version, explain why the project is unaffected,
and be removed when the lock file no longer contains the finding.

Runtime deployments must:

- read webhook URLs, API keys, MCP credentials, and private endpoints from
  mounted secret files or references, never public YAML;
- use least-privilege network policy and read-only observer credentials;
- run as a numeric non-root user with a read-only root filesystem and no Linux
  capabilities;
- make only the SQLite data path and a bounded temporary path writable;
- keep every SQLite path ancestor controlled by the operator and unwritable by
  untrusted principals;
- suppress Discord mentions and URLs in generated content by default;
- enforce output, context, conversation, timeout, and rate limits; and
- avoid logging secrets, complete prompts, complete MCP responses, private
  endpoints, or unrelated user messages.

The production operational listener exposes only fixed value-free `/livez`,
`/readyz`, and `/startupz` responses. It is unauthenticated because it carries no
application data or diagnostics, but it is still an inbound interface and must
be reachable only by the orchestrator through deployment network policy. It
must not be published through an ingress or public Service.

Generic schemas and environment-neutral examples belong in this public
repository. Real deployment configuration, encrypted Secrets, endpoint
inventories, and private overlays belong in a separate private repository.

## Reporting a vulnerability

Use the private security-advisory feature of the repository hosting this
project. Do not include credentials, private infrastructure output, Discord
content, or personal data in a public issue.

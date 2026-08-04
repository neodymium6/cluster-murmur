# Security Policy

## Supported versions

There are no supported releases yet. The current repository is a bootstrap
and must not be connected to production or sensitive systems.

## Security boundary

Cluster Murmur consumes bounded, read-only observations and publishes generated
messages. It does not own infrastructure credentials, raw infrastructure APIs,
probe execution, mutation, remediation, or unrestricted tool use.

Factual decisions such as failure, recovery, severity, and state transitions
must be made by deterministic application code. LLMs may only turn supplied
facts into persona-specific language. Tool access must remain disabled by
default and, if introduced later, must use application-enforced allowlists and
strict call, round, timeout, and concurrency limits.

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

Generic schemas and environment-neutral examples belong in this public
repository. Real deployment configuration, encrypted Secrets, endpoint
inventories, and private overlays belong in a separate private repository.

## Reporting a vulnerability

Use the private security-advisory feature of the repository hosting this
project. Do not include credentials, private infrastructure output, Discord
content, or personal data in a public issue.

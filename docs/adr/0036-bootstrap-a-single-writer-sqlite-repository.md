# ADR 0036: Bootstrap a Single-Writer SQLite Repository

## Status

Accepted.

## Context

ADR 0011 selected Ecto with SQLite, but the application does not yet have a
repository process or a deployment-safe database-path contract. Schema work
should build on one reviewed connection boundary without making domain modules
issue arbitrary SQL.

## Decision

Supervise one `Ecto.Repo` using the SQLite adapter. Use one pooled connection,
immediate transactions, WAL journaling, foreign-key enforcement, and a bounded
busy timeout. Disable SQL query logs and sensitive connection-error details by
default because future parameters may contain observation or conversation data.

Use an isolated in-memory database for tests. Require a bounded absolute path
from `CLUSTER_MURMUR_DATABASE_PATH` in production, while development defaults to
the ignored `.local` directory, and reject in-memory storage outside tests.
Require the selected database's immediate parent to exist with mode `0700`, and
create only the database file with mode `0600` inside it. Require those exact
permission bits from existing paths and reject symlinks or incompatible file
types at the immediate boundary. The private directory protects the database
and its adjacent WAL and shared-memory files from other local users. Reject
generic Ecto URL options so they cannot override the validated path or
connection bounds after repository initialization. Classify invalid
configuration without returning rejected values.

Treat the complete path ancestry as trusted deployment input: it must contain no
symlink components and must not be writable by untrusted principals. The
standard Elixir file API and current SQLite adapter do not provide an
`openat`-style race-safe no-follow boundary to this repository. Pathname checks
therefore catch accidental misconfiguration but do not defend against a
principal capable of replacing path components concurrently. Adding a no-follow
adapter boundary would be a separate hardening decision.

Do not add schemas, migrations, generic query passthrough, retention jobs, or
domain stores in this change.

## Consequences

The application now proves that its SQLite connection can start under the root
supervisor with deterministic safety settings. Follow-up migrations and stores
can be added in small domain-specific changes. SQLite remains a single-instance
boundary; horizontal writers and production recovery procedures are still out
of scope. Deployments must keep database ancestry outside untrusted writable
directories.

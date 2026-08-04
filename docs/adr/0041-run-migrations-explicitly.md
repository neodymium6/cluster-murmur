# ADR 0041: Run Database Migrations Explicitly

## Status

Accepted.

## Context

The first domain store requires a migrated schema, but application startup must
not silently change durable state. Mix tasks are also unavailable inside a
self-contained release.

## Decision

Add one explicit OTP release operation that applies every migration packaged for
the single configured repository. Operators invoke `migrate!/0` with the
release's `eval` command, which provides an extracted filesystem for the SQLite
NIF and migration files. The bootstrap escript remains version-only. Use the
repository's fixed application migration path and a single connection.

Require operators to stop every application instance before migration. Reject
the operation when the application or named repository is running in the
evaluation VM, but do not represent that local check as a cross-process or
distributed lock: it cannot detect an independently running release VM. Reject
overlapping migration calls within one VM with a single-owner lock.

Track the exact applications and repository process started by the operation;
stop only those owned resources and reject cleanup failures. Run the database
migration work in a monitored process with a 60-second bound. Suppress primary
logging until that process, the owned repository, and every application started
for migration have stopped, and disable migration, migrator, and SQL logging.
Classify startup exceptions, linked exits, cleanup failures, and timeouts without
exposing paths, SQL, parameters, applied versions, or configuration values. Keep
repeated runs idempotent and make `migrate!/0` raise only a generic
release-evaluation error.

Accept only the repository set compiled into the application. Do not reuse a
live repository, accept caller-selected repositories or paths, expose rollback,
or deploy the application through this operation. Operators invoke the exact
revision deliberately before starting it.

## Consequences

The OTP release has a reviewed, black-box-tested schema preparation boundary
without granting arbitrary database access. A failed migration stops release
evaluation with a generic error and requires operator investigation through the
private deployment environment. Rollback and recovery procedures remain
separate operational decisions.

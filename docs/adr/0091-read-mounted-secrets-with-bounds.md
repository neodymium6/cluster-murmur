# ADR 0091: Read Mounted Secrets with Fixed Bounds

## Status

Accepted.

## Context

Public configuration contains environment-variable names rather than API keys
or webhook URLs. Runtime startup needs a narrow way to resolve those names and
load mounted secret files without turning configuration loading into an
unbounded file-reading capability or exposing sensitive diagnostics.

## Decision

Resolve one validated portable environment-variable name to an absolute path.
Require the resolved target to be a regular file, while allowing symlinks used
by projected secret volumes. Read at most 16 KiB plus one detection byte,
require valid UTF-8, trim surrounding whitespace, and reject an empty result.

Return stable error atoms that contain neither the environment value, path, nor
file contents. Treat the loaded value as opaque: API-key and webhook-URL
validation belong to their separate startup settings boundaries. Deployment
controls remain responsible for mounting the file read-only with appropriate
ownership and permissions.

## Consequences

Secret values remain outside public documents and direct environment-variable
values. Startup consumers can share one bounded loader without sharing the
secret through diagnostics. A configured environment variable can identify
only one mounted file, and each consumer must still validate the resulting
value for its specific purpose.

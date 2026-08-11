# 0193. Load fixed observer MCP settings

Date: 2026-08-11

## Status

Accepted; amended by ADR 0202.

## Context

The Cluster Observer request and response boundaries already restrict runtime
calls to two named read-only tools, but no production boundary resolves the
observer endpoint or authentication. A standalone runtime needs those inputs
without placing private deployment values or credentials in public YAML and
without turning configuration loading into authorization to connect.

## Decision

Load the observer endpoint from the fixed
`CLUSTER_MURMUR_OBSERVER_MCP_URL` environment variable and its bearer token only
from the mounted file named by the fixed
`CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE` environment variable. Bound the
endpoint to 2,048 bytes and use the shared mounted-secret limit of 16 KiB.

Require a normalized URL with the exact `/mcp` path and no user information,
query, or fragment. Require HTTPS except for plain HTTP connections to the
explicit loopback hosts `localhost`, `127.0.0.1`, and `::1`, which support a
same-host sidecar. Return a typed settings value whose inspection omits both
fields and whose errors never contain deployment values. Revalidate the exact
value before transport use.

Do not connect, select tools, or expose a generic HTTP capability while loading
these settings. The fixed transport and standalone application assembly remain
separate reviewed changes.

## Consequences

A deployment can supply a private observer endpoint and mounted credential
through a narrow, redacted boundary. Remote observer traffic is encrypted by
construction, while a local sidecar can terminate transport security without
allowing plain HTTP to arbitrary hosts. Startup still cannot contact an
observer until the later fixed transport and assembly explicitly consume these
settings.

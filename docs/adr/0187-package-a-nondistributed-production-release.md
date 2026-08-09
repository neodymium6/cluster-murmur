# 0187. Package a nondistributed production release

Date: 2026-08-09

## Status

Accepted

## Context

The Nix checks built an ad hoc Mix release, but the flake exposed no reusable
production package. Mix release scripts also default to a distributed Erlang
node and a generated cookie even though this single-writer application has no
clustered-node or remote-control contract. Embedding that cookie in the Nix
store would misrepresent a generated build value as a deployable secret.

## Decision

Expose the production Mix release as the flake's default
`cluster-murmur` package. Fetch dependencies by their existing fixed hash,
compile Exqlite against the pinned system SQLite, include ERTS, and let the Nix
builder remove its generated cookie file.

Set the release profile to nondistributed mode. Supply a clearly public
placeholder only because the generated launch script requires a cookie argument
even when distribution is disabled. Pin the packaged VM argument files and
clear inherited Erlang and Elixir VM flag channels so they cannot re-enable a
named node with that public placeholder. Do not expose Erlang remote control or
accept runtime distribution overrides.

Run version, successful migration, database permission, and redacted migration
failure checks against the packaged output rather than a second ad hoc release.

## Consequences

`nix build .#cluster-murmur` produces the same immutable release that later OCI
packaging can consume. The release remains single-instance and cannot be
remotely attached through Erlang distribution. Any future distributed runtime
would require a separate security design and reviewed secret injection path.

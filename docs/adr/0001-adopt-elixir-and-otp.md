# ADR 0001: Adopt Elixir and OTP

## Status

Accepted.

## Context

The service coordinates independent pollers, timers, event processing, dynamic
conversations, provider calls, and graceful shutdown. These components need
fault isolation and explicit lifecycle supervision.

## Decision

Implement Cluster Murmur as the Elixir application `:cluster_murmur` on
Erlang/OTP. Use supervised processes for runtime lifecycles and plain immutable
data for domain values.

## Consequences

OTP supervision, behaviours, registries, and deterministic message passing are
first-class tools. The runtime and release image must include the BEAM, and the
team must avoid turning every domain entity into a process.

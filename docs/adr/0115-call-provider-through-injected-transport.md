# ADR 0115: Call the Provider Through an Injected Transport

## Context

The fixed request encoder and bounded response decoder do not yet implement the
provider behaviour. A concrete adapter must connect them without exposing a
generic HTTP capability, provider diagnostics, or implicit retry behavior.

## Decision

Extend the provider behaviour with exact loaded settings and a narrow injected
one-request transport. The OpenAI-compatible adapter encodes and immediately
revalidates the request, invokes the transport exactly once, and decodes only
the fixed response capability.

Accept only explicit not-sent timeout or unavailable transport failures and one
outcome-unknown result. Map an unknown outcome or a raised transport to
`unavailable`; map malformed transport values to `invalid_response`. Never retry
inside the adapter.

## Consequences

Tests and later orchestration can inject a deterministic transport without
gaining arbitrary methods, paths, headers, or options. All public adapter
results remain within the existing external error contract. Provider invocation
may have an unknown remote effect, but generation can safely choose its
deterministic fallback because this adapter performs no automatic retry.

# 0198. Execute bounded OpenAI-compatible HTTP requests

Date: 2026-08-11

## Status

Accepted; CA-store initialization amended by ADR 0222

## Context

The provider settings, prompt projection, fixed chat-completions request,
bounded response decoder, and stable transport result now exist, but no shipped
adapter performs the HTTP exchange. Runtime assembly needs one live transport
without exposing arbitrary HTTP or weakening the request's prompt and settings
provenance.

## Decision

Add a generation-specific Mint transport that accepts only an exact
`OpenAICompatibleRequest` and the fixed `ProviderSettings`. Reconstruct the
closed `PromptRequest` projection from the bounded JSON body, rebuild the whole
request through the existing encoder, and require exact equality before
connecting. Open one passive HTTP/1 connection, send one POST, receive one
response, and close it without
redirects, retries, proxies, pooling, cookies, decompression, or alternate
methods.

Apply one monotonic overall deadline across connection, request send, response
receive, and TLS cleanup. Limit connection setup to five seconds, reset the
socket send timeout to the remaining deadline, and use a single address-family
attempt. Verify HTTPS peers with the operating-system CA store, hostname
verification, and TLS 1.2 or 1.3. Preserve the existing provider-settings
decision that plain HTTP is an explicit operator-selected endpoint.

After Mint initializes the connection, reset and verify the transport receive
buffer at 4 KiB. Bound each response header section to 16 KiB, the accumulated
body to 64 KiB, and all HTTP bytes admitted to the parser to 96 KiB. Require one
JSON content type for a successful response; classify non-success responses by
status without interpreting their media type. Return only the bounded response
capability or the narrow not-sent, outcome-unknown, and invalid-response
classes.

Keep this executor generation-specific even though the observer executor uses
the same defensive Mint pattern. A generic shared request function would create
an arbitrary HTTP capability that neither domain boundary should expose.

## Consequences

Runtime assembly can inject a live provider closure while preserving the
existing deterministic test seam and stable fallback behavior. Each generation
pays connection and TLS setup cost, but gains explicit lifecycle and retry
semantics. Transport logic is intentionally duplicated across two fixed domain
adapters rather than generalized into an unsafe passthrough.

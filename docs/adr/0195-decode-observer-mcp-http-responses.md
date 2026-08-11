# 0195. Decode bounded observer MCP HTTP responses

Date: 2026-08-11

## Status

Accepted

## Context

The fixed MCP HTTP request boundary produces one stateless `tools/call`
request. MCP 2026-07-28 permits a server to return either one JSON object or a
request-scoped Server-Sent Events stream containing notifications before the
final response. Neither raw form should cross into observation logic.

## Decision

Accept an exact redacted response value containing an HTTP status, a normalized
JSON or event-stream format, and at most 64 KiB of body bytes. Decode every JSON
value with the shared depth, node, collection, number, and text budgets. For
SSE, ignore comments and envelope fields, join `data` lines, share one JSON
budget across all events, ignore bounded JSON-RPC notifications, and require
the correlated final response to be the last data event.

Accept only JSON-RPC version 2.0, fixed request ID 1, a complete non-error tool
result with a content list, and present `structuredContent`. Re-encode only that
structured value into the existing redacted `MCPResponse`; its operation-aware
decoder remains responsible for the exact observer schema.

Map authentication, invalid-request, and rate-limit HTTP rejections to their
stable known outcomes. Allowlist only standard client-caused JSON-RPC codes and
the MCP header-mismatch code as invalid requests. Treat internal, custom, and
unknown protocol errors or HTTP server errors as outcome unknown. Discard
protocol diagnostics, tool diagnostics, notifications, and raw bodies. Do not
retry or perform network I/O here.

## Consequences

A later HTTP executor can support both response formats required by MCP without
granting notifications or remote diagnostics any application behavior. The
64 KiB limit applies to the complete wire response, so envelope overhead makes
the accepted structured result slightly smaller than the existing application
limit. HTTP media-type normalization, streaming collection, and connection
execution remain the next reviewed boundary.

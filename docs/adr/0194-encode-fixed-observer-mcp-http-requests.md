# 0194. Encode fixed observer MCP HTTP requests

Date: 2026-08-11

## Status

Accepted

## Context

The observer boundary fixes two read-only tool calls, and the connection
settings fix one endpoint and mounted bearer token. A live adapter still needs
an MCP wire request, but exposing a generic HTTP builder or accepting a tool
catalog would weaken the application-owned capability boundary.

MCP 2026-07-28 uses stateless requests rather than the initialization and
session lifecycle from earlier protocol revisions. Its
[Streamable HTTP transport][mcp-http] requires a POST with matching protocol,
method, and tool-name metadata in the body and headers.

## Decision

Encode only a validated `MCPRequest` and validated `MCPSettings` into one fixed
MCP 2026-07-28 `tools/call` JSON-RPC request. Include the required client
metadata, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, JSON and SSE accept
types, content type, and bearer authorization. Use one fixed request ID because
each operation occupies its own stateless HTTP request.

Carry the operation's 15-second overall and receive timeout, a five-second
connect timeout, and its 64 KiB response limit. Redact the endpoint, token,
tool, arguments, headers, and body from inspection. Rebuild and compare every
field immediately before a later HTTP adapter uses the request.

Do not discover tools, accept server-selected parameter headers, support legacy
MCP sessions, or perform network I/O in this boundary. The application already
owns the exact schemas and does not derive authority from an untrusted server
catalog.

## Consequences

The later live adapter receives a complete request without gaining a general
HTTP or tool-selection interface. The implementation intentionally supports
only MCP 2026-07-28 servers and fails closed instead of negotiating legacy
session behavior. Response envelope and HTTP execution remain separate
reviewed changes.

[mcp-http]: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http

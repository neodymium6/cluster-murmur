# 0196. Execute bounded observer MCP HTTP requests

Date: 2026-08-11

## Status

Accepted; CA-store initialization amended by ADR 0222

## Context

The fixed observer request and response boundaries now define the complete MCP
2026-07-28 wire contract, but no production adapter performs the HTTP exchange.
The adapter must enforce body limits while bytes arrive, including for error
statuses, and must not turn redirects, proxies, retries, or pooling into hidden
authority.

OTP `httpc` streams only 200 and 206 response bodies. A large rejection body
would therefore be materialized before the application could enforce its
64 KiB limit.

## Decision

Use Mint as a low-level process-less client. For every observer operation,
rebuild and revalidate the fixed MCP HTTP request, open one passive HTTP/1
connection, send one POST, consume response chunks up to the request's 64 KiB
limit, decode the normalized JSON or event-stream response, and close the
connection. Limit response headers to 16 KiB and the complete operation to its
existing 15-second deadline. Apply the connect limit once, then reset the socket
send timeout to the operation's remaining time before dispatch so a blocked
request write cannot outlive that deadline. Bound TLS connection cleanup by the
same remaining deadline rather than allowing a separate close timeout.

After Mint's connection initialization, reset and verify each transport's
user-space receive buffer at 4 KiB, then admit at most 96 KiB of total HTTP wire
bytes. This outer allowance covers the 64 KiB decoded body, 16 KiB header
section, and bounded protocol framing, and prevents partial status lines, chunk
metadata, or other parser-buffered bytes from growing until the time deadline
alone stops them.

For HTTPS, require peer verification, the operating-system CA store, hostname
verification supplied by Mint, and TLS 1.2 or 1.3. Retain the settings boundary's
loopback-only exception for plain HTTP and resolve each accepted spelling to an
actual loopback address without DNS. Do not configure a proxy, redirect, retry,
persistent pool, cookie store, decompression, or alternate HTTP method.
Use one IPv4 connection attempt for DNS hostnames so address-family fallback
cannot spend the connect budget twice. Operators that require IPv6 must provide
an explicit IPv6 literal, which selects one IPv6 attempt instead.
Construct the HTTP authority for that literal with the required brackets while
retaining its unbracketed form for TLS verification.

Classify connection failures before request dispatch as not sent. Once Mint is
asked to send the request, classify transport errors, timeouts, and unexpected
exceptions as outcome unknown. Oversized or malformed completed responses
remain invalid responses. Never return Mint diagnostics, endpoint values,
headers, credentials, or raw bodies.

## Consequences

The existing `MCPClient` can receive a live transport closure without gaining
an arbitrary HTTP capability. Every call pays connection and TLS setup cost,
which is acceptable for bounded polling and keeps lifecycle, credential, and
failure semantics explicit. The new Mint and HPAX packages become production
dependencies and remain fixed by `mix.lock` and the Nix dependency hashes.

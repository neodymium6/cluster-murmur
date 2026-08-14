# 0201. Execute Discord webhooks over bounded HTTPS

Date: 2026-08-11

## Status

Accepted; CA-store initialization amended by ADR 0222

## Context

The publisher already assembles and independently validates one fixed Discord
incoming-webhook request, then durably claims its dispatch before invoking an
injected one-argument transport. The standalone runtime needs a production
implementation of that narrow transport without exposing arbitrary HTTP or
weakening the conservative publication recovery contract.

Discord webhook credentials cannot safely be redirected to loopback endpoints.
Connecting to a live destination from repository tests would also violate the
project's deployment boundary. Response accumulation therefore needs a pure,
separately tested state machine while the production executor remains fixed to
the independently validated Discord authority.

## Decision

Add a live transport that:

- revalidates the complete request against startup-captured webhook settings;
- connects only to `discord.com` over verified TLS 1.2 or 1.3 and passive
  HTTP/1;
- performs one request with the fixed `wait=true` query, without redirects,
  retries, proxies, pooling, or caller-selected HTTP values;
- shares one deadline across connection, serialization, dispatch, response,
  and bounded TLS cleanup;
- enforces bounded socket buffers, response headers, body bytes, and raw parser
  input; and
- returns a known `not_sent` failure only before dispatch, while every abnormal
  outcome after dispatch is conservatively `outcome_unknown`.

A successful HTTP 200 response must have exactly one JSON media type. Rejection
responses are allowed to carry another media type because their bodies remain
bounded and are discarded by the response classifier.

## Consequences

The runtime can construct a one-argument transport closure by capturing one
validated `WebhookSettings` value. It gains no generic network capability and
cannot change the credential, authority, method, headers, query, payload, or
limits supplied by application code.

Repository tests cover pre-connect rejection and the complete incremental
response state machine without contacting Discord. A separately authorized
deployment smoke test remains responsible for proving connectivity with a real
operator-owned webhook.

# 0200. Classify unsent webhook validation failures

Date: 2026-08-11

## Status

Accepted; amends ADR 0112.

## Context

The Discord publisher durably claims a dispatch before invoking its static
transport. A live transport will revalidate the exact request against its
startup-captured webhook setting. If that local validation fails, no network
request was sent, but the existing transport contract can express only timeout
or unavailable as proven pre-send failures. Treating this result as malformed
or outcome unknown would unnecessarily mark a known local rejection ambiguous.

## Decision

Allow the narrow Discord transport to return
`{:error, :not_sent, :invalid_request}`. Preserve that stable class as a failed
dispatch alongside existing proven not-sent timeout and unavailable outcomes.
Continue treating malformed transport return values, raised transports, and
every failure after dispatch begins as ambiguous.

Do not expose the rejected field, webhook credential, message content, parser
diagnostic, or raw transport error.

## Consequences

A request that fails the final fixed transport boundary remains durably claimed
but can be completed as a known invalid-request failure without implying a
possibly accepted Discord message. Retry policy remains outside the transport,
and no new destination or HTTP capability is introduced.

# ADR 0113: Encode Fixed OpenAI-Compatible Requests

## Context

The provider behaviour accepts a separated, provider-neutral prompt, while the
runtime settings boundary resolves deployment values. Passing either value
directly to a generic HTTP client would permit forged fields, unbounded bodies,
arbitrary paths, or unsafe header values to cross the external boundary.

## Decision

Encode only the OpenAI-compatible chat-completions shape. Revalidate the exact
prompt and loaded settings, append the fixed `/chat/completions` path, set the
method and headers in application code, and carry fixed response and transport
bounds. Encode the separated persona, confirmed facts, creative context, and
conversation as JSON data inside one user message; keep the fixed factual rule
as the system message.

The request struct redacts its URL, headers, model, and prompt data from
inspection. A second validation operation rebuilds and compares every field
immediately before a future adapter performs transport.

## Consequences

Callers cannot add provider parameters, arbitrary headers, paths, or transport
options through this capability. The API key remains a runtime header value but
does not appear in normal inspection. This boundary performs no network call,
does not decode a response, and does not decide whether generated text is safe
to publish.

# ADR 0087: Validate Bounded Generation Context

## Status

Accepted. Amended by
[ADR 0233](0233-make-generation-conversation-first.md).

## Context

Prompt assembly must keep persona identity, factual data, creative framing, and
conversation history separate. Validating only each source independently would
still allow an oversized combined request or unordered, forged history.

## Decision

Add one exact redacted generation context containing a dedicated persona
projection, validated fact projection, closed creative context, and chronological
conversation lines. The persona projection contains only a display name and
instructions; selection identity, avatar, interests, behavior, relationships,
and metadata cannot cross this boundary. Creative context contains only a portable conversation kind
and a short nonblank single-line mood. Each history line contains a bounded
single-line display name, safe UTF-8 content, and a canonical UTC ordering
instant. History content may preserve line feeds from validated messages; the
prompt assembler must carry it as structured data rather than interpret it as a
section delimiter.

Accept at most 12 lines in nondecreasing order. Reject unexpected fields,
improper lists, every control character and Unicode line separator in single-line fields, every history
content control other than line feed, invalid nested capabilities, and a
combined 128 KiB text budget across persona identity and instructions,
serialized facts, creative framing, and conversation text. Keep ordering
instants for validation; the prompt assembler need not expose them to the
provider.

## Consequences

The next prompt stage receives one bounded capability whose four input classes
remain distinct. It cannot silently add arbitrary context categories, reorder
history, or combine individually valid values into an unbounded provider
request.

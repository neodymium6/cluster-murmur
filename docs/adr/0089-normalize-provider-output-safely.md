# ADR 0089: Normalize Provider Output Mechanically

## Status

Accepted. Amended by [ADR 0226](0226-classify-provider-output-rejections.md).

## Context

Provider responses need a small deterministic boundary before message
construction. The normalizer must handle malformed or oversized responses and
remove provider presentation artifacts without becoming a second content-policy
engine.

Runtime facts supplied to an approved provider may contain operator-approved
private infrastructure information. Detecting every Unicode, Markdown, domain,
or address representation is neither a reliable confidentiality boundary nor
the responsibility of text normalization. Sensitive-data selection and
redaction remain upstream application concerns.

## Decision

Add a pure provider-output normalizer with a 64 KiB raw byte bound. Require valid
UTF-8, an exact validated persona projection, and an injected character limit
between 1 and 16 KiB.

Replace C0 and C1 controls other than line feed with spaces, collapse horizontal
whitespace, and trim the result. Replace controls with spacing rather than
deleting them so separate factual tokens cannot be joined.

Remove at most one exact leading display-name label using a closed colon or dash
delimiter set. Normalize whitespace in the validated display name only for this
comparison. Require whitespace or end-of-input after the delimiter so a prefix
match cannot consume ordinary content.

After mechanical normalization and label removal, enforce the injected
character limit and delegate blankness, byte bounds, and existing output policy
to the shared message content validator. Return only
`:invalid_provider_output`; never include provider content in errors.

Do not add an independent URL, address, Markdown, Unicode-confusable, or Discord
parser to this component. Publication-specific controls, including disabling
Discord mention expansion, belong to the publication boundary.

## Consequences

Provider output receives deterministic bounded cleanup without duplicating
content policy. The application remains responsible for selecting and redacting
facts before prompting, and the shared message and publication boundaries retain
their separate responsibilities.

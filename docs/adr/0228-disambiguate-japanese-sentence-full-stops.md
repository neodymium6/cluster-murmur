# ADR 0228: Disambiguate Japanese Sentence Full Stops

## Status

Accepted. Amends [ADR 0066](0066-validate-runtime-messages.md).

## Context

The ideographic full stop (`U+3002`) is both Japanese sentence punctuation and
an IDNA domain-label separator. Fullwidth and halfwidth full stops have similar
compatibility behavior. Mapping every such character to an ASCII dot before
domain detection correctly rejected Unicode-dot domains and IP addresses, but
also misclassified ordinary multi-sentence Japanese output such as
`今日は正常です。クラスタは静かです。` as a domain-like form.

Removing Unicode-dot normalization would admit alternate domain and address
spellings. Treating every ideographic full stop as sentence punctuation would
have the same unsafe effect. The validator therefore needs a narrow,
deterministic distinction that remains independent of provider interpretation.

## Decision

Normalize generated content with NFKC once. URL, network-path, and IP-address
checks continue to map every ideographic, fullwidth, and halfwidth dot to an
ASCII dot.

For only the domain scan, process each complete line independently. Treat its
ideographic full stops as sentence boundaries when the whole line consists of
two or more clauses made only from Japanese scripts and bounded Japanese
punctuation, with no inter-sentence whitespace, and every clause ends with one
member of a fixed closed set of Japanese sentence endings followed by an
ideographic full stop. Map those sentence boundaries to token separators. In
every other line, including lines with Latin reference cues, fixed Japanese
network-reference cues, whitespace between sentences, or path punctuation,
map all Unicode dot variants to ASCII dots as before. Split and validate clauses
directly so maximum-size near matches do not trigger repeated-regex
backtracking.

Keep the accepted-ending set in application code. Do not ask an LLM to
classify punctuation, expand the public rejection vocabulary, return rejected
content, or log content while making this decision.

## Consequences

Ordinary bounded Japanese sentence chains can cross the output boundary.
Explicit Unicode-dot references, Unicode-dot IP addresses, a domain followed
by sentence punctuation, and mixed lines that do not wholly satisfy the closed
sentence form continue to fail closed.

A bare Japanese sentence chain can also be a syntactically valid IDNA label
chain. Raw text alone cannot distinguish those two interpretations. The
validator resolves that ambiguity in favor of the narrowly closed Japanese
sentence structure above; callers cannot use this exception for text carrying
the fixed reference cues or other network syntax. Japanese expressions outside
that fixed set still share the unavoidable sentence-versus-IDNA ambiguity.

The accepted Japanese forms are intentionally finite. Valid prose outside the
closed form can still be rejected and may require a reviewed extension. This
tradeoff prefers false rejection over weakening the network-reference safety
boundary.

# ADR 0088: Assemble Separated Generation Prompts

## Status

Accepted.

## Context

Generation input is validated as four distinct bounded categories. Rendering
those values into a delimited text template would allow supplied line breaks or
delimiter-like content to blur the distinction between instructions, facts,
creative framing, and history.

## Decision

Assemble a provider-neutral redacted prompt request only after validating the
complete generation context. Keep the fixed application instruction, persona
identity and instructions, confirmed fact map, creative context, and ordered
conversation in separate fields. Convert facts through their existing fixed
allowlisted prompt projection. Convert history lines to exact speaker/content
maps and omit their ordering timestamps after validation.

Never interpolate supplied values into the fixed application instruction or
render any of these categories as delimiter-separated text. Provider adapters
may encode the request for a specific API, but must preserve these boundaries.
Narrow the provider behavior to this prompt-request type instead of an arbitrary
map. Each concrete adapter must reject forged or extended request values before
performing an external call.

## Consequences

Provider integration receives one closed structured capability whose inspection
is redacted. Multiline history remains a data string rather than becoming prompt
syntax, and selection identifiers, source metadata, and ordering timestamps do
not enter the provider request.

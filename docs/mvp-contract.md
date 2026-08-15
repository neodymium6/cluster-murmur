# MVP runtime contract

This document set records the concrete behavior that the standalone MVP must
satisfy. The [system design](../DESIGN.md) explains architecture and ADRs
explain material decisions; these contract pages define testable runtime
invariants and completion criteria.

The keywords **must**, **must not**, **should**, and **may** are normative. The
complete set describes source version `0.2.0-alpha.5`. The
[v0.1.0-alpha.1 boundary](public-alpha.md) records a narrower historical subset
and does not narrow this current contract.

## Normative sections

All pages below form one normative MVP runtime contract:

1. [System boundary and domain values](contracts/domain.md) defines ownership,
   exclusions, and validated public values.
2. [External service contracts](contracts/external-services.md) defines the
   narrow observer, model-provider, publication, clock, randomness, and
   persistence interfaces.
3. [Runtime behavior](contracts/runtime-behavior.md) defines observation,
   trigger, conversation, generation, and publication invariants.
4. [Persistence and sensitive data](contracts/persistence-and-data.md) defines
   durable records, bounded logging, and redaction.
5. [Operations and acceptance](contracts/operations-and-acceptance.md) defines
   probes, shutdown, verification, and completion criteria.

Implementation and tests may add stricter private constraints, but they must not
weaken any invariant in this contract set.

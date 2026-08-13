# Cluster Murmur system design

The historical public alpha established the bounded domain, persistence,
orchestration, recovery, and opt-in scheduling components. The standalone alpha
adds fixed live transports, automatic recovery-gated OTP assembly, operational
probes and telemetry, single-writer deployment controls, attested release
publication, and isolated entry-point and end-to-end checks.

## Design sections

1. [Boundaries and design principles](docs/design/boundaries-and-principles.md)
   defines project identity, responsibilities, exclusions, and the separation
   between observed facts and generated expression.
2. [Runtime and domain design](docs/design/runtime-and-domain.md) explains the
   event-to-conversation pipeline, domain values, triggers, generation,
   publication, and persistence.
3. [Production architecture and evolution](docs/design/production-and-evolution.md)
   explains configuration, recovery-gated OTP supervision, deployment,
   verification, and bounded post-MVP evolution.

## Related normative references

The [configuration reference](docs/configuration.md) defines accepted public
input. The [MVP runtime contract](docs/mvp-contract.md) defines testable
invariants and acceptance criteria. The
[deployment guide](docs/deployment.md) defines supported artifacts and
operational procedures.

The [v0.1.0-alpha.1 boundary](docs/public-alpha.md), release notes, and ADRs are
historical evidence. They explain how the design evolved but do not override
the current normative references.

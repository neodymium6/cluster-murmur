# Configuration reference

This reference defines the complete public configuration contract for the
standalone alpha. Loading, validation, startup preparation, fixed live
transports, and production runtime assembly are implemented. Concrete
configuration, mounted secrets, endpoints, storage, network policy, and rollout
remain deployment-owned.

Configuration controls observations, event policy, personas, bindings,
triggers, generation limits, and outbound routing. It must never contain
credentials, webhook URLs, private endpoints, or environment-specific
identifiers.

## Normative sections

All pages below form one normative configuration reference:

1. [Loading and validation](configuration/loading-and-validation.md) defines
   bounded YAML decoding, includes, schemas, and validation failures.
2. [Paths and runtime defaults](configuration/paths-and-defaults.md) defines
   root and database paths, state tracking, conversation bounds, and event
   policy.
3. [Domain configuration](configuration/domain.md) defines event groups,
   personas, bindings, and event, recurring, and stochastic triggers.
4. [External integrations](configuration/integrations.md) defines fixed LLM,
   Discord, and observer settings.
5. [Runtime operations](configuration/runtime.md) defines scheduler cadence,
   responder timing, probes, and mounted-secret handling.

Read the [deployment guide](deployment.md) after selecting configuration. It
defines the required artifact, storage, process, and rollout controls.

## Historical scope

The [v0.1.0-alpha.1 boundary](public-alpha.md) documents an older tagged subset
and is retained only as historical evidence. It does not narrow this current
reference.

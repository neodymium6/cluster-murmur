# Documentation

Start with the root [README](../README.md) for the project summary and local
development commands. This index separates current guidance from historical
evidence so readers do not need to infer which document is authoritative.

## Choose a path

### Evaluate or configure Cluster Murmur

- Understand architecture and component ownership: [system design](../DESIGN.md).
- Write or validate public configuration: [configuration reference](configuration.md).
- Check exact runtime invariants and acceptance criteria:
  [MVP runtime contract](mvp-contract.md).
- Run the isolated observer-to-publication example:
  [isolated end-to-end example](../examples/isolated-end-to-end/README.md).

### Build, operate, or release it

- Build artifacts, prepare SQLite, and review runtime controls:
  [deployment and artifact guide](deployment.md).
- Adapt the non-deployable hardened Kubernetes base:
  [Kubernetes example](../deploy/kubernetes/README.md).
- Publish or verify a digest-pinned image, SBOM, and provenance:
  [published release artifacts](deployment.md#published-release-artifacts).
- Review trust boundaries and report vulnerabilities:
  [security policy](../SECURITY.md).
- Understand retained static-analysis exceptions:
  [Dialyzer boundaries](dialyzer-boundaries.md).

### Investigate history

- Review shipped changes: [changelog](../CHANGELOG.md).
- Browse tagged boundaries and release evidence in the
  [project history](history/README.md).
- Find the reason behind a material design choice in the
  [categorized ADR index](adr/README.md).

## Authority and document roles

The configuration reference defines accepted deployment input. The MVP runtime
contract defines testable behavior. The deployment guide defines the supported
artifact and operational procedure. These current normative references take
precedence over historical release notes and amended ADRs.

The system design explains how current components fit together. ADRs preserve
why material decisions were made. Release notes and the public alpha boundary
describe particular tagged revisions and must not be treated as current
configuration or operational guidance.

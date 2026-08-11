# Documentation

Start with the root [README](../README.md) for the project summary and local
development commands. Use the documents below for details.

## By task

- Review the historical `v0.1.0-alpha.1` scope and known limitations:
  [public-alpha.md](public-alpha.md).
- Write or validate public configuration:
  [configuration.md](configuration.md).
- Build artifacts, prepare SQLite, or review runtime controls:
  [deployment.md](deployment.md).
- Adapt the non-deployable hardened Kubernetes base:
  [deploy/kubernetes](../deploy/kubernetes/README.md).
- Publish or verify a digest-pinned tagged image, SBOM, and provenance:
  [deployment.md](deployment.md#published-release-artifacts).
- Run the isolated observer-to-publication example:
  [examples/isolated-end-to-end](../examples/isolated-end-to-end/README.md).
- Understand architecture and component ownership: [DESIGN.md](../DESIGN.md).
- Check exact runtime invariants and acceptance criteria:
  [mvp-contract.md](mvp-contract.md).
- Review trust boundaries, sensitive data handling, and vulnerability reporting:
  [SECURITY.md](../SECURITY.md).
- Understand retained Dialyzer filters:
  [dialyzer-boundaries.md](dialyzer-boundaries.md).
- Review shipped changes: [CHANGELOG.md](../CHANGELOG.md) and the
  [v0.1.0-alpha.1 release notes](release-notes-v0.1.0-alpha.1.md).

## Document roles

The configuration reference and MVP contract are deliberately comprehensive
normative references. `DESIGN.md` explains the overall target architecture,
including work beyond the public alpha. `docs/adr/` records individual material
decisions and their context. Release notes summarize one published revision and
must not replace the normative documents.

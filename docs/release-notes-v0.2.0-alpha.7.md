# Cluster Murmur v0.2.0-alpha.7

This release adds bounded controls and redacted diagnostics for reasoning-capable
OpenAI Chat Completions models. It remains an alpha rather than a
production-support commitment or authorization to connect the software to
sensitive systems.

## Reasoning model controls

- The finite `max_output_tokens` ceiling is raised from 4,096 to 32,768 so an
  operator can reserve a combined completion budget suitable for initial
  reasoning-model evaluation.
- The optional `reasoning_effort` configuration accepts only `none`, `minimal`,
  `low`, `medium`, `high`, `xhigh`, or `max` and is encoded using the current
  Chat Completions field.
- Omitting reasoning effort preserves the previous request shape and the
  configured endpoint's default. The application does not infer model support
  or expose a generic provider-parameter passthrough.
- Loaded provider settings retain finite timeout, request, response, and
  conversation limits, and exact correlation checks reject settings changed
  after configuration loading.

## Token-exhaustion diagnostics

- Successful provider responses validate present closed finish reasons and
  bounded nonnegative completion and reasoning token counts without returning
  the metadata to conversation code.
- Null or blank content with `finish_reason: "length"` becomes the stable
  `token_exhausted` error. Nonblank partial content remains eligible for the
  existing output normalizer, while other blank output retains the existing
  deterministic fallback path.
- Fixed operational telemetry reports reasoning-budget exhaustion as
  `component=model_provider outcome=error error_class=token_exhausted`.
- Prompts, response content, raw bodies, token counts, credentials, endpoints,
  and arbitrary provider diagnostics are not logged or added to telemetry.

These changes make a reasoning-budget fallback distinguishable from a normal
provider success whose visible text is rejected later by output normalization.
Provider failures and rejected output still produce the same bounded factual
fallback without retrying or giving the model factual decision authority.

## Release artifacts

The release contains one digest-addressed `linux/amd64` OCI image with at most
20 layers, an SPDX SBOM, checksums, release metadata, and signed provenance and
SBOM attestations. No mutable version or `latest` image tag is published.

A reviewed version-matching tag runs the full repository gate and creates a
draft prerelease. Publishing that reviewed draft starts a separate public
distribution smoke workflow that verifies the asset set, checksums, metadata,
image identity, and attestations.

## Deployment boundary

The repository does not contain live credentials, private endpoints, real
configuration, deployable overlays, or authorization to contact infrastructure,
a model provider, or Discord. Before any deployment, review the exact immutable
image digest, configuration, mounted secrets, network policy, storage, backup,
migration, rollback, probes, telemetry, and rollout settings in the operator's
private repository.

See the [configuration reference](configuration.md),
[deployment and artifact guide](deployment.md),
[MVP runtime contract](mvp-contract.md), and [security policy](../SECURITY.md)
before evaluating a deployment.

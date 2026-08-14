# 0222. Initialize the CA certificate store before standalone workers

Date: 2026-08-14

## Status

Accepted

## Context

The three fixed HTTPS transports obtain their trust anchors from
`:public_key.cacerts_get/0`. The Nix OCI image includes a valid CA bundle and
sets `SSL_CERT_FILE`, but OTP does not necessarily load that environment path
into its process-wide certificate store. In the minimal image this left the
store empty, so observer, model-provider, and Discord connections failed before
request dispatch even though the configured file existed and was readable.

Letting each transport discover or load certificates independently would add
environment and filesystem authority to three otherwise narrow request
boundaries. Allowing the standalone runtime to start without any trust anchors
would defer one deterministic configuration failure until scheduled work had
already been claimed.

## Decision

Initialize the OTP CA certificate store once in the standalone application
before constructing or starting any child. When `SSL_CERT_FILE` is configured,
require an absolute, UTF-8, NUL-free path of at most 4,096 bytes whose final
target is a non-empty regular file no larger than 4 MiB. Load that file through
`:public_key.cacerts_load/1`, then require `:public_key.cacerts_get/0` to return
at least one certificate. If the variable is absent, retain OTP's platform
certificate discovery but still require its resulting store to be non-empty.

Map missing files, invalid targets, oversized bundles, loader failures, empty
stores, exceptions, and malformed injected boundaries to one stable error that
does not expose the path, certificate contents, or loader details. Do not
perform this initialization for the repository-only development and test
application.

Keep certificate lookup inside each fixed transport unchanged. The packaged
OCI image continues to set `SSL_CERT_FILE` to its immutable Nix CA bundle, and
the extracted-entrypoint smoke test must verify that the started application
exposes a non-empty store. This decision amends the implicit CA-source
assumptions in ADRs 0196, 0198, and 0201 and the image verification boundary in
ADR 0188.

## Consequences

The minimal OCI image can establish verified TLS connections through the same
fixed transports without giving them a generic file or environment interface.
A broken trust-store configuration now prevents all standalone workers from
starting, so schedulers cannot consume run allowances while every outbound
request is guaranteed to fail before dispatch.

Host deployments that omit `SSL_CERT_FILE` remain compatible when OTP can load
a non-empty platform store. A configured bundle becomes an explicit bounded
startup input and must be present before application startup. The bundle-size
check assumes deployment-owned certificate files are immutable for the life of
the process, matching the read-only image and reviewed private-overlay model.

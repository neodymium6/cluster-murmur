# 0218. Define single-writer Kubernetes operations

Date: 2026-08-11

## Status

Accepted

## Context

The immutable image has a single-writer SQLite repository and fixed production
entry point, but no upstream orchestration example defines replica ownership,
migration ordering, backup consistency, rollback constraints, or the Cluster
Observer relationship. A generic rolling Deployment could overlap writers, and
copying only a live SQLite main file could omit committed WAL state.

## Decision

Ship a deliberately non-deployable Kubernetes base with fake registries,
digests, endpoints, and RFC 5737 egress addresses. Require a private reviewed
overlay for every real value. Use one replica, `Recreate`, one private
`ReadWriteOnce` volume, a 35-second termination grace, and a same-image init
container that invokes only the fixed packaged migration operation. Add stable
`/bin/cluster-murmur` and `/bin/tini` image entry points so orchestration does not
depend on Nix store paths.

Run both application and observer-sidecar containers as numeric non-root user
65532 with the runtime-default seccomp profile, no service-account token, no
privilege escalation, no capabilities, a read-only root filesystem, explicit
resource limits, and separate bounded memory-backed `/tmp` volumes. Require the
storage provisioner or private overlay to provide the volume root as
`65532:65532` with exact mode `0700`; do not apply Pod `fsGroup`, which can widen
the application's required exact storage modes. Mount public configuration and
Secrets read-only, and mount only the application container's private SQLite
volume writable. Create no Service or Ingress.

Default network policy to deny Pod ingress and allow only cluster DNS and
reviewed HTTPS egress destinations. Standard NetworkPolicy keeps same-node
probe traffic outside Pod ingress isolation and cannot express FQDN policy, so
the public manifest requires platform verification and uses only fake
documentation addresses. Require an egress gateway or reviewed CNI-specific
overlay for real destinations. Prefer a loopback Cluster Observer sidecar that
alone owns narrow read-only infrastructure access; alternatively require an
authenticated HTTPS observer service. Never mount Kubernetes credentials into
Cluster Murmur.

Require offline, full-volume backups after every writer and migrator has stopped.
Record the application version, image digest, migration set, snapshot identity,
and time. Restore to a new volume and validate with one isolated Pod. Run only
forward packaged migrations. After a schema-incompatible migration, rollback
means restoring the pre-upgrade snapshot and previous digest; no database
downgrade operation is exposed.

Explicitly defer referenced-lifecycle compaction. Existing retention deletes
only expired unreferenced events, so referenced records may outlive the configured
window. Operators must monitor and capacity-plan storage rather than bypassing
foreign-key ownership or running manual SQL deletion.

## Consequences

The example demonstrates the supported security and lifecycle shape without
claiming portability across storage classes, CNIs, probe sources, registries, or
secret systems. Recreate rollout causes downtime but prevents intended writer
overlap and allows migration before runtime startup. Platform failure can still
leave attachment uncertainty, so storage fencing and operator verification
remain required.

Backups are application-consistent and rollback behavior is explicit. Conservative
retention favors referential integrity over fixed storage lifetime until a
separate reviewed compaction design exists.

# Hardened Kubernetes example

This directory is a non-deployable base for a single Cluster Murmur replica.
Its image registries, digests, namespace, egress addresses, Cluster Observer
container, public configuration, and Secret are deliberate placeholders. Do
not apply it until a private reviewed overlay replaces every placeholder for one
exact environment and revision.

## Required private overlay

Pin both images by reviewed immutable digest. Supply the namespace and storage
class, a `cluster-murmur-public-config` ConfigMap containing the complete public
configuration tree, and a `cluster-murmur-secrets` Secret with these exact keys:

- `observer-token`;
- `model-api-key`; and
- `discord-webhook`.

Secret values, private endpoints, observer inventory, adapter configuration,
persona prompts, routing, and real egress ranges do not belong in this
repository. Keep them in the
operator-owned private infrastructure repository. Validate the rendered YAML
and its image digests before applying it.

The example intentionally creates no Service or Ingress. Kubelet probes use the
named container port directly. Standard NetworkPolicy permits traffic between a
Pod and its node, so the base adds no Pod ingress peer. Confirm the selected
CNI's node-origin probe behavior and add only the required host policy in the
private overlay when its behavior differs.

Standard NetworkPolicy cannot select DNS names. Replace all three RFC 5737
egress addresses with reviewed fixed egress gateways or use a reviewed
FQDN-aware policy implementation for the model provider, Discord, and any
observer-sidecar dependencies. The selected CNI must enforce both ingress and
egress NetworkPolicy.

## Observer relationship

The preferred shape is a dedicated Cluster Observer sidecar in the same Pod.
Cluster Murmur then uses the fixed loopback HTTP `/mcp` endpoint, and the
sidecar owns its narrowly scoped read-only infrastructure access. Replace the
placeholder sidecar with a reviewed image, command, probes, configuration, and
network policy. The example projects only the observer bearer token into that
container; it cannot read the model or Discord credentials. Do not give the
Cluster Murmur container Kubernetes API tokens, kubeconfigs, generic query
authority, or the observer infrastructure credentials.

A separately deployed observer is also supported when its endpoint is HTTPS,
authenticated with the mounted bearer token, and restricted by network policy.
Remove the sidecar and change only the documented observer endpoint in the
private overlay.

## External event adapter

The optional
[`external-ingestion-sidecar.example.yaml`](external-ingestion-sidecar.example.yaml)
is a strategic-merge patch showing the intended trust boundary. It adds a
placeholder normalizing adapter to the same Pod, gives both containers one
dedicated ingestion token, and sends normalized events to the fixed loopback
endpoint. It is deliberately absent from this base's `kustomization.yaml`.

A private overlay may include the patch only after replacing the image digest,
adapter-specific environment interface, TLS Secret, resource limits, and
network policy. Add a Service or ingress only for the adapter's authenticated
TLS port; never publish Cluster Murmur's loopback ingestion or health listener.
The adapter must bound and authenticate its raw input, make firing/resolved
decisions deterministically, and emit only the allowlisted normalized schema.
It must not forward raw payloads or accept prompts, personas, routes, tools,
credentials, or arbitrary destination URLs.

## Single-writer rollout

Keep `replicas: 1`, the `Recreate` strategy, and one private persistent volume.
Do not add an HPA, start a second Deployment against the volume, or rely on
`ReadWriteOnce` as an application-level writer lock. Provision the mounted
volume root for numeric user and group `65532:65532` with exact mode `0700`;
do not use Pod `fsGroup`, because its recursive permission changes conflict with
the application's exact `0700` parent and `0600` database-file checks. The
replacement Pod runs the fixed packaged migration operation in an init
container only after the old Pod has terminated, then starts the application
against the same volume.

The built-in Secret projection cannot select a non-root file owner. The example
therefore projects read-only `0444` files into only the container that needs
each value. Each container runs one fixed process with no arbitrary execution
boundary. Use a reviewed CSI secret driver that supports UID `65532` and mode
`0400` when the platform requires owner-only secret files.

The 35-second termination grace covers readiness removal and the five bounded
scheduler shutdown windows. Preserve the database volume after Pod or node
failure and let startup recovery finish before treating the replacement as
ready.

## Backup, restore, and upgrade

Take application-consistent backups offline:

1. stop the Deployment and verify no application, migration init container, or
   maintenance workload has the volume attached;
2. take an atomic snapshot of the complete persistent volume, including any
   SQLite WAL and shared-memory files, or use a trusted SQLite backup tool while
   the volume remains offline;
3. record the application version, exact image digest, completed migration
   versions, snapshot identifier, and creation time without recording secrets;
4. restore into a new volume rather than overwriting the only backup; and
5. validate the restored volume with exactly one isolated Pod using the recorded
   image before changing the production reference.

For an upgrade, take and validate the backup first, stop the old replica, update
the immutable digest and public configuration together, and let the replacement
init container apply packaged forward migrations. Wait for startup and readiness
before admitting any dependent workflow.

Before a migration, rollback can select the previous image and configuration.
After a migration, do not start an older image unless its documented schema
contract explicitly supports the new schema. The release exposes no database
downgrade command. Restore the pre-upgrade snapshot to a new volume and use the
previous digest when a schema-incompatible rollback is required.

## Retention consequence

Current retention removes only expired events that are no longer referenced by
durable lifecycle records. Referenced events can therefore outlive the configured
retention window and increase volume usage. Monitor persistent storage and
capacity-plan for this conservative behavior; do not bypass references or run
manual SQL deletion. Referenced-lifecycle compaction remains explicitly deferred.

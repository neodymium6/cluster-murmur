# Deployment and artifact guide

## Scope

The public alpha is a composable engine, not a standalone service or a supported
production release. The default OTP application starts only the SQLite
repository. Building or loading an artifact does not authorize connecting it to
infrastructure, a model provider, or Discord.

A deployment must supply and review its own runtime assembly, transports,
configuration paths, secret mounts, storage, network policy, health integration,
telemetry, and rollout policy.

## Build the OTP release

Build the immutable, nondistributed release from the pinned Nix inputs:

```bash
nix build .#cluster-murmur
```

The release contains no generated Erlang cookie. Runtime configuration,
credentials, external transports, and worker assembly are not included.

## Prepare SQLite

Set `CLUSTER_MURMUR_DATABASE_PATH` to an approved absolute path. Its existing
parent directory must be private and controlled by the runtime identity. Stop
every application instance that uses the database before running migrations.

For local artifact evaluation, create a private ignored directory and apply the
packaged migrations explicitly:

```bash
mkdir -p .local
chmod 0700 .local
CLUSTER_MURMUR_DATABASE_PATH="$PWD/.local/cluster-murmur.sqlite3" \
  ./result/bin/cluster_murmur eval \
  'ClusterMurmur.Release.migrate!()'
```

Application startup never runs migrations automatically. Migration failures use
a stable redacted error and must be resolved before starting runtime work. The
[configuration reference](configuration.md) defines the complete database-path
validation and migration contract. A deployment operator must separately
provision its persistent parent directory with mode `0700` and ownership for the
runtime identity.

## Build the container archive

The container artifact is available on Linux:

```bash
nix build .#container-image
docker image load -i result
```

The scratch-based image:

- runs as numeric user and group `65532:65532`;
- starts the nondistributed release through Tini;
- declares no ports, volumes, health check, credentials, or deployment
  configuration; and
- includes standard OCI labels and the complete runtime closure.

Repository checks validate the archive metadata and closure, remove write
permission except from the intended temporary and data paths, migrate an
isolated database, and smoke-run the extracted entrypoint. These archive-level
checks do not apply container-runtime mount, identity, or privilege controls.

## Required container controls

A runtime must:

- make the root filesystem read-only;
- drop every Linux capability and disable privilege escalation;
- mount a size-bounded private tmpfs at `/tmp`, owned by `65532:65532`;
- mount private persistent storage at `/var/lib/cluster-murmur`, owned by
  `65532:65532`;
- set `CLUSTER_MURMUR_DATABASE_PATH` to an absolute path below that private
  storage; and
- apply least-privilege network policy for only the reviewed fixed transports.

For Docker-compatible runtimes, the hardening profile includes `--read-only`,
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, and a bounded tmpfs such
as:

```text
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,uid=65532,gid=65532,mode=0700
```

The database bind mount and all remaining runtime settings remain private
deployment inputs.

## Deployment-owned runtime

A live deployment must explicitly assemble the reviewed opt-in supervisors and
workers with:

- validated public configuration and private configuration paths;
- `CLUSTER_MURMUR_OBSERVER_MCP_URL` set to the reviewed fixed `/mcp` endpoint;
- `CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE` and other mounted credential-file
  references;
- fixed MCP, model-provider, and Discord transports;
- a production clock and random source;
- the narrow public persistence adapters;
- health, metrics, logging, and restart integration; and
- platform-specific storage, network, and rollout policy.

These inputs must not introduce generic shell, SSH, `kubectl`, SQL, arbitrary
PromQL, or arbitrary HTTP passthrough capabilities. See the
[public alpha boundary](public-alpha.md) and [security policy](../SECURITY.md)
before designing an assembly.

# Cluster Murmur

Cluster Murmur gives observed systems a cast of characters. When a read-only
observer reports a meaningful change or an ambient activation fires, configured
personas can begin a short bounded conversation in Discord. Operational facts can
ground the dialogue without turning every exchange into a status report.

It is ambient character software for experiencing what is happening around a
running system. It is not a monitoring system, an incident-response tool, or an
autonomous infrastructure agent.

## From a system change to a conversation

Suppose an observer reports that a workload changed from healthy to degraded.
Cluster Murmur can turn that fact into an exchange like this:

> **Observed fact:** A workload became degraded.
>
> **Mira:** "One of the workloads seems a little unwell."
>
> **Noa:** "I noticed it too. Let's see what happens next."

This exchange is illustrative. The characters, tone, triggers, and destination
come from deployment-owned configuration. Application-supplied facts constrain
claims about the real system, while personas may also produce harmless
fictional conversation.

The complete path is deliberately narrow:

```text
read-only observation
        -> application-defined event
        -> matching trigger and personas
        -> short, bounded conversation
        -> Discord message
```

Application code decides whether an observation represents an event, which
trigger matches, who may participate, and whether anything should be
published. A model receives only bounded, allowlisted context and writes
conversation in a persona's voice. Confirmed operational facts constrain what
it may claim about the real system without forcing every message to be a report.

## What it is for

Cluster Murmur is intended for:

- giving a running system a sense of character and presence;
- turning selected state changes into approachable, character-driven
  commentary; and
- creating occasional, bounded conversations rather than a stream of raw
  telemetry.

It deliberately does not replace alerts, dashboards, logs, or incident
response. It cannot remediate a system or provide generic shell, SSH,
`kubectl`, SQL, PromQL, or HTTP access. Infrastructure observation remains a
separate read-only responsibility.

## Safety model

Every conversation is bounded by turns, participants, duration, model calls,
cooldowns, response sizes, and stored history, and it always has an explicit
no-reply path. Observation data is allowlisted before it reaches generation,
and publication uses fixed transports with mentions disabled.

Observation data and generated prompts may still be sensitive. Public
configuration must not contain credentials, webhook URLs, private endpoints,
real cluster identities, or private persona content. See the
[system design](DESIGN.md) and [security policy](SECURITY.md) for the complete
trust boundary.

## Try it without external effects

The isolated end-to-end example exercises the path from a synthetic degraded
observation to a captured Discord-shaped publication. It uses loopback
listeners, fake credentials, and an in-process destination; it does not connect
to infrastructure, a model provider, or Discord.

```bash
nix develop
mix deps.get
mix test test/cluster_murmur/runtime/isolated_end_to_end_test.exs
```

See the [example walkthrough](examples/isolated-end-to-end/README.md) for the
asserted lifecycle and isolation boundaries.

## Project status

Cluster Murmur is a public standalone alpha. The current source version is
`0.2.0-alpha.11`; published artifacts are listed on the
[GitHub Releases page](https://github.com/neodymium6/cluster-murmur/releases).

The standalone alpha includes fixed observer, OpenAI-compatible, and Discord
transports; bounded orchestration; durable SQLite state; restart recovery;
operational probes; and packaged release artifacts. Credentials, endpoints,
routing, storage, and rollout policy remain deployment-owned inputs.

Do not connect this revision to production, sensitive infrastructure, model
providers, or Discord without reviewing the exact deployment configuration,
environment, and revision.

## Development and builds

Install repository hooks and run the standard checks from the pinned
development environment:

```bash
nix develop
mix deps.get
just init
just check
```

Run the dependency retirement and security-advisory gate with `just audit`.
Build the packaged OTP release with `nix build .#cluster-murmur`. On Linux,
build the Docker-compatible image archive with `nix build .#container-image`.

Building an artifact does not authorize running it against live systems. The
[deployment and artifact guide](docs/deployment.md) covers migrations, storage,
container controls, release publication, and deployment-owned inputs.

## Documentation

Use the [documentation index](docs/README.md) to choose the right level of
detail. The main references are:

- [System design](DESIGN.md)
- [Configuration reference](docs/configuration.md)
- [Deployment and artifact guide](docs/deployment.md)
- [MVP runtime contract](docs/mvp-contract.md)
- [Hardened Kubernetes example](deploy/kubernetes/README.md)
- [Public alpha boundary](docs/public-alpha.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)
- [Architecture decisions](docs/adr/)

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).

# ADR 0118: Prepare Runtime Inputs Before Startup

## Context

Configuration loading and deployment-setting resolution are independently
bounded, but callers still need one ordered startup boundary. Constructing
workers after only one stage succeeds could defer invalid configuration or
missing secrets until external work has already begun.

## Decision

Prepare the complete normalized configuration first, then load the redacted
provider and webhook settings aggregate from it. Return one exact redacted
prepared value only after both stages succeed and revalidate that value before
runtime construction.

Preparation reads bounded public configuration, environment variables, and
mounted secret files. It does not start a worker, connect to infrastructure or
a model provider, or publish a message. Errors retain only the stable
configuration or runtime-settings stage and its already redacted reason.

## Consequences

Later application-supervision work can require one validated prepared value
instead of reopening files or resolving deployment settings lazily. Process
ownership, transport injection, and worker startup remain separate reviewed
decisions.

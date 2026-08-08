# ADR 0149: Compose an Authorized Conversation Pipeline

## Status

Accepted.

## Context

The starter coordinator can return an exact reply continuation, and the
responder initializer and runner can consume that capability through a finite
explicit schedule. Opt-in runtime assembly still needs one boundary that joins
those vertical slices without accepting replacement policy, stores, or
settings after the starter has published.

## Decision

Add an opt-in authorized-conversation coordinator. Before the starter's first
mutation, validate its complete runtime, the responder adapter contracts, the
entire bounded responder schedule, and the schedule's correlation with the
starter completion instant and configured duration deadline. Require both
vertical slices to share their conversation, message, provider, publication,
and cooldown adapters.

Run the existing starter pipeline exactly once. Return its terminal, skipped,
failed, or ambiguous result unchanged. Only an exact reply continuation may be
projected by the responder initializer and passed to the bounded responder
runner. Derive all responder settings and policy inputs from the already
validated starter input, and perform no retries or ambient scheduling.

## Consequences

A caller can explicitly opt one authorized action into complete bounded
conversation execution without gaining a capability to replace the starter's
configuration, cooldown snapshot, provider settings, webhook settings, or
durable stores. Poll scheduling and supervision remain separate composition
steps.

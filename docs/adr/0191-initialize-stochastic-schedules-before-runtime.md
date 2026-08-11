# 0191. Initialize stochastic schedules before runtime

Date: 2026-08-11

## Status

Accepted

## Context

The stochastic scheduler can process only durable schedule versions already
correlated with the current configuration. New triggers need an initial sampled
run, while removed triggers need their stale state retired. Performing either
operation after live cycles begin could race claims or let a partial sampling
failure leave a partially initialized runtime.

## Decision

Add one bounded stochastic schedule initializer. Validate the complete
configuration, one canonical UTC startup instant, the injected random contract,
and the fixed store adapter before sampling or persistence. Select at most 256
stochastic triggers in identifier order and calculate every initial next run
before the first storage mutation.

After successful calculation, retire one bounded page of state absent from the
active trigger set, then restore or initialize active schedules in identifier
order. Existing durable versions always win. Correlate each returned claim-free
schedule with its configured trigger and accept only an exact unsaturated
retirement result. Return aggregate schedule count only.

Do not read a clock, loop over saturated retirement pages, start a worker, or
perform external I/O. A later recovered runtime supervisor must inject the
startup instant and production random source and must fail startup when this
initializer is incomplete.

## Consequences

Stochastic startup becomes deterministic in ordering and bounded in storage
effects even though initial intervals are sampled. Sampling failure causes no
storage mutation. Configuration drift is reconciled before live claims begin,
and a saturated stale page requires another explicit startup pass.

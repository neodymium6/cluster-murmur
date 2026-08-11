# 0214. Build recovery-gated production runtime options

Date: 2026-08-11

## Status

Accepted.

## Context

Production option builders now cover all five runtime schedulers. The shared
recovery supervisor still needs one correlated aggregate plus the recurring and
stochastic startup initializers. Its existing preflight was private to
`start_link/2`, where successful validation immediately reads the clock and
runs recovery and initialization.

## Decision

Expose `RecoveredRuntimeSupervisor.validate/1` as the effect-free form of its
existing exact option and default recovery-store contract checks. It must not
read the clock or run a startup gate.

Add `ProductionRecoveredRuntimeOptions.build/1`. Combine the conversation and
background production scheduler options, fix the initializers to
`RecurringScheduleInitializer` and `StochasticScheduleInitializer`, fix the
shared clock to `SystemClock`, and pass the aggregate through the new preflight.

## Consequences

The application entry point can receive one validated option value for the
existing all-or-nothing recovery supervisor without selecting modules. Calling
the builder does not recover records, initialize schedules, read time, start a
process or timer, access external services, or execute a runtime cycle. Those
effects remain exclusively behind the supervisor's explicit start boundary.

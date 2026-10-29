# Documentation

This index lists every documentation page of the package.

## Concepts

- [Execution model](reference/execution-model.md): States where sessions run, what the worker boundary protects and what it costs, how the pool is sized, grown and reused, and how feeds, protocol turns, callbacks, printing and close behave.
- [Upstream divergences](reference/upstream-divergences.md): Lists every known place where dart_monty_core behaves differently from pydantic-monty 1.2.0, and why.

## Running code

- [Host functions and async](deep-dives/async-matrix.md): Gives the behaviour of each host-function answer and `await` combination.
- [Host modules](reference/host-modules.md): States how a host module is built, registered, imported and called, and how it differs from a lookup value.
- [OS access](reference/os-access.md): Describes OS handlers, in-memory files, host-backed virtual files, and OS policy.
- [Telemetry](reference/telemetry.md): Defines the telemetry adapter and signal failure behavior.

## Testing

- [The fake session](reference/fake-session.md): Explains when to use `FakeMontySession`, how a test drives it, and its limits.

## OS and files

- [Host directory mounts](reference/host-directory-mounts.md): States how `MountDir` maps a host directory into the sandbox, with its modes, budgets, routing and platform limits.

## Platforms

- [Native worker](native-worker.md): States how native programs find, install, verify, and bundle worker executables.

## Releases

- [Package versioning](reference/versioning.md): Defines the relationship between package and upstream versions.

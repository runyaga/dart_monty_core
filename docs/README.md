# Documentation

This index lists every documentation page of the package.

## Concepts

- [Execution model](reference/execution-model.md): States where sessions run, what the worker boundary protects and what it costs, how the pool is sized, grown and reused, and how feeds, protocol turns, callbacks, printing and close behave.
- [Upstream divergences](reference/upstream-divergences.md): Lists every known place where dart_monty_core behaves differently from pydantic-monty 1.1.0, and why.

## Running code

- [Host functions and async](deep-dives/async-matrix.md): Gives the behaviour of each host-function answer and `await` combination.

## Testing

- [The fake session](reference/fake-session.md): States how `FakeMontySession` scripts a feed, the OS calls it knows, the answers it records and its limits.

## OS and files

- [Host directory mounts](reference/host-directory-mounts.md): States how `MountDir` maps a host directory into the sandbox, with its modes, budgets, routing and platform limits.

## Platforms

- [Native worker](native-worker.md): States how native programs find, install, verify, and bundle worker executables.

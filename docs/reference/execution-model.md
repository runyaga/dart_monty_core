# Execution model and its fault boundary

`dart_monty_core` never runs the monty interpreter in your process. Every
session runs in a worker: a child process on native platforms, a Web Worker
in the browser. This page says what that boundary protects and what it costs.

## The short version

| | worker | crash isolation | hard preemption |
|---|---|---|---|
| **Native** (VM, AOT) | child process | yes | yes: the parent kills the process |
| **Web** (dart2js, dart2wasm) | Web Worker | yes | yes: `terminate()` |

A memory fault inside sandboxed Python (a stack-overflow abort, a wasm trap)
ends that worker, not your app. [`MontySession`](../../lib/src/worker/monty_session.dart)
defines its session outcome, and [`Monty`](../../lib/src/worker/monty.dart)
defines worker replacement.

[`MontySession`](../../lib/src/worker/monty_session.dart) defines the distinct
failure paths for worker allocation and interpreter resource limits.

## Workers isolate interpreter faults

A Rust process cannot catch every memory abort. Upstream runs the interpreter
only in worker
subprocesses:

> Monty executes untrusted Python, and a Monty process can never be made fully
> crash-proof against memory errors (stack overflow aborts, allocator aborts).
> This crate isolates those crashes by running the interpreter **only in worker
> subprocesses** […] a crashed worker kills only itself, the pool detects the
> death and replaces the worker, and the parent process is never at risk.
>
> Upstream `crates/monty-pool/README.md`

`dart_monty_core` follows the same rule. `native/worker/` mirrors upstream's
`monty subprocess` worker, and `Monty` is the pool upstream's `AsyncMonty` is.

Dart isolates would not do: they have separate heaps but share one OS
process, so a native abort takes down every isolate with the host, and an
isolate blocked in a native call cannot be killed until it returns.

## Limits and deadlines use different failure paths

[`ResourceLimits`](../../lib/src/worker/resource_limits.dart) governs failures
raised cooperatively inside the interpreter. The worker's allocator provides a
separate hard boundary outside that interpreter. The two paths differ in
session survival and traceback availability, as defined by
[`MontySession`](../../lib/src/worker/monty_session.dart).

The parent adds a wall-clock backstop around worker turns.
[`Monty.start`](../../lib/src/worker/monty.dart) and
[`MontySession`](../../lib/src/worker/monty_session.dart) define its deadlines,
grace, and kill behavior. Host callbacks run between worker turns, so this
backstop can kill the worker but cannot preempt host code.

## Pools allocate and reuse workers

One pool owns the workers, grows as concurrent checkouts need capacity, and
dedicates one worker to each session. Sessions can therefore run in parallel,
while one session serializes its turns on its worker. The pool reuses or retires
a worker after session close.

[`Monty`](../../lib/src/worker/monty.dart) defines pool ownership, checkout,
cleanup, and the nested-checkout hazard. The
[`Monty.start`](../../lib/src/worker/monty.dart) defines sizing, waiting,
startup, request, and recycling limits.

## Feeds and protocol turns have different boundaries

A **feed** is one execution of code. A **protocol turn** is one request and its
answer. A feed can span several turns because host interaction suspends it.
This distinction determines queueing, deadlines, callback timing, dumps, and
close behavior.

[`MontySession`](../../lib/src/worker/monty_session.dart) defines the complete
turn and close contract. [`MontySnapshot`](../../lib/src/worker/monty_snapshot.dart)
defines manual and automatic suspension handling.

## Host filesystem service

`MountDir` serves filesystem calls through upstream `monty-fs` in the Dart
host process. The interpreter still runs only in the worker. Python sees
virtual paths, while the mount service owns the host directory capabilities.
Mount calls are synchronous FFI calls and can block the calling Dart isolate.
A worker kill does not preempt a host filesystem call already in progress.

Mount memory remains separate from worker interpreter memory. See
[host directory mounts](host-directory-mounts.md) for the cross-component
routing and lifetime.

The worker cdylib also contains the mount service. Its allocator is separate
from each worker process's allocator in this process-only architecture.
Any future in-process interpreter must revisit that separation: mount
allocations must not charge the interpreter's memory budget or share its
process-fatal hard limit. The current mount packaging is not approval to
combine them in one allocator domain.

## Costs

Each session holds one worker for its life, and every value crossing the worker
boundary is encoded and copied. Native consumers also need a worker executable
or the build-hook opt-in described in the README's platform section. Pool
capacity and deadlines belong to the linked declarations above.

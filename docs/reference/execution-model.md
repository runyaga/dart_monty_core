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
ends that worker, not your app. The call in flight fails
with `MontyCrashedError` and the session with it; the pool starts a new worker
for the next checkout.

A worker that exits because its allocator refused an allocation over the hard
limit fails the call with `MontyRuntimeError` carrying `MemoryError`, and the
session ends.

## Why a worker

A Rust process cannot be made crash-proof against memory errors; those aborts
cannot be caught. Upstream's answer is to run the interpreter only in worker
subprocesses:

> Monty executes untrusted Python, and a Monty process can never be made fully
> crash-proof against memory errors (stack overflow aborts, allocator aborts).
> This crate isolates those crashes by running the interpreter **only in worker
> subprocesses** […] a crashed worker kills only itself, the pool detects the
> death and replaces the worker, and the parent process is never at risk.
>
> — upstream `crates/monty-pool/README.md`

`dart_monty_core` follows the same rule. `native/worker/` mirrors upstream's
`monty subprocess` worker, and `Monty` is the pool upstream's `AsyncMonty` is.

Dart isolates would not do: they have separate heaps but share one OS
process, so a native abort takes down every isolate with the host, and an
isolate blocked in a native call cannot be killed until it returns.

## Limits, deadlines and the kill

Resource limits (`ResourceLimits`, passed to `checkout`) are enforced by the
interpreter at cooperative points, and the session survives them:

```dart
final session = await monty.checkout(
  limits: const ResourceLimits(
    maxMemory: 32 << 20,
    maxRecursionDepth: 200,
    maxFeedDuration: Duration(seconds: 5),
  ),
);
```

`maxFeedDuration` stops a non-terminating loop with `TimeoutError`,
`maxRecursionDepth` turns runaway recursion into `RecursionError`, and
`maxMemory` raises `MemoryError`; each arrives as `MontyRuntimeError`.
On dart2js and dart2wasm, a session that keeps the allocation which exhausted
`maxMemory` raises `MemoryError` on every later feed until a feed drops it.

What limits cannot cover, the worker boundary does:

- `requestTimeout` on `Monty.start` bounds each protocol turn. Past it the
  parent kills the worker, and the call fails with `MontyCrashedError` whose
  `timedOut` is true.
- `feedDurationLimitGrace` and `turnDurationLimitGrace` are how far past a
  session's own duration limits the parent lets a turn run before it kills
  the worker, for a worker that stops answering.
- `MontySession.close()` during a turn kills the worker.
- A worker whose allocator refuses an allocation over its hard limit exits;
  the call fails with `MontyRuntimeError` carrying `MemoryError` and the
  session ends.

## Host filesystem service

`MountDir` serves filesystem calls through upstream `monty-fs` in the Dart
host process. The interpreter still runs only in the worker; Python sees
virtual paths, while the mount service owns the host directory capabilities.
Mount calls are synchronous FFI calls and can block the calling Dart isolate.
Killing a worker does not preempt a host filesystem call already in progress.

`MountDir.memoryUsageLimit` accounts for retained overlay data and transient
filesystem results. It is separate from the worker interpreter's
`ResourceLimits.maxMemory`. `writeBytesLimit` is cumulative within each feed
and resets at the next feed. See [host directory mounts](host-directory-mounts.md).

The worker cdylib also contains the mount service. Its allocator is separate
from each worker process's allocator in this process-only architecture.
Any future in-process interpreter must revisit that separation: mount
allocations must not charge the interpreter's memory budget or share its
process-fatal hard limit. The current mount packaging is not approval to
combine them in one allocator domain.

## Costs

- Each session holds one worker for its life. `maxProcesses` bounds the
  workers alive at once, and a `checkout` beyond it waits, forever unless
  `checkoutTimeout` is set.
- Values cross the boundary encoded, so every input, host function call and
  result is copied.
- Native consumers need a worker executable, or the build-hook opt-in and
  `runMontyWorkerIfChild` (see the README's Platforms section).

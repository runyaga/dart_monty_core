# Execution model and its fault boundary

`dart_monty_core` never runs the monty interpreter in your process. Every
session runs in a worker: a child process on native platforms, a Web Worker
in the browser. This page says what that boundary protects and what it costs.

## The short version

| | worker | crash isolation | hard preemption |
|---|---|---|---|
| **Native** (VM, AOT) | child process | yes | yes: the parent kills the process |
| **Web** (dart2js, dart2wasm) | Web Worker | yes | yes: `terminate()` |

A memory fault inside sandboxed Python (a stack-overflow abort, an allocator
abort, a wasm trap) ends that worker, not your app. The call in flight fails
with `MontyCrashedError` and the session with it; the pool starts a new worker
for the next checkout.

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

What limits cannot cover, the worker boundary does:

- `requestTimeout` on `Monty.start` bounds each protocol turn. Past it the
  parent kills the worker, and the call fails with `MontyCrashedError` whose
  `timedOut` is true.
- `feedDurationLimitGrace` and `turnDurationLimitGrace` are how far past a
  session's own duration limits the parent lets a turn run before it kills
  the worker, for a worker that stops answering.
- `MontySession.close()` during a turn kills the worker.
- A worker whose allocator refuses an allocation over its hard limit exits;
  that too is `MontyCrashedError`.

## Costs

- Each session holds one worker for its life. `maxProcesses` bounds the
  workers alive at once, and a `checkout` beyond it waits, forever unless
  `checkoutTimeout` is set.
- Values cross the boundary encoded, so every input, host function call and
  result is copied.
- Native consumers need a worker executable, or the build-hook opt-in and
  `runMontyWorkerIfChild` (see the README's Platforms section).

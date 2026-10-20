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

`maxSuspensions` and `maxTotalSleep` are the exception: the parent counts
them, not the interpreter. Every suspension is counted as the parent
receives it, and every system sleep — `time.sleep` and `asyncio.sleep`
alike — is charged, cut to the OS policy's system-sleep maximum, before it
is waited. Both add up over the whole checkout, across every feed and
resume, never per feed: `maxSuspensions` defaults to 1000 and cannot be
turned off, and `maxTotalSleep` is off unless set. The one that would pass
a budget aborts the feed with an in-sandbox `RuntimeError` or
`TimeoutError` that sandbox code cannot catch and Dart sees as
`MontyRuntimeError`; the session runs on.

What limits cannot cover, the worker boundary does:

- `requestTimeout` on `Monty.start` bounds each protocol turn. Past it the
  parent kills the worker, and the call fails with `MontyCrashedError` whose
  `timedOut` is true.
- `feedDurationLimitGrace` and `turnDurationLimitGrace` are how far past a
  session's own duration limits the parent lets a turn run before it kills
  the worker, for a worker that stops answering. Each is one second by
  default; null leaves its limit unguarded by the parent.
- `MontySession.close()` during a turn kills the worker.
- A worker whose allocator refuses an allocation over its hard limit exits;
  the call fails with `MontyRuntimeError` carrying `MemoryError` and the
  session ends.

## Feeds, protocol turns, callbacks, printing and close

A **feed** is one execution of code: `feedRun` runs it to its end;
`feedStart` runs it to its first suspension and each resume runs it to the
next. A **protocol turn** is one request the parent sends the worker — a
feed, a resume, a dump, a load, an install — and the one event that
answers it. Turns are serialized per session, as upstream's checkout lock
serializes them; feeds are not. A feed that suspends and resumes spans
several turns, and while its host call is answered the turn is free. A
new feed waits only for the turn in flight: it runs when the earlier feed
has finished, and is refused with `StateError` once that feed suspends. A
dump is no call's turn: it runs between turns, so a host function may
dump its own session while its call waits.

- **Host callbacks** run outside every turn: `externalLookup` entries,
  host-function calls, `os:` handlers and the host work behind `resumeAuto`
  execute in the Dart process between turns. They may take as long as they
  like; `requestTimeout` and the duration backstops do not count them. A
  `close` while one runs fails the call waiting on it at once, as finished;
  the callback is not interrupted, and its answer is dropped when it comes.
- **Printing** runs inside the turn. Each print delivery is awaited before
  the next event is read, the turn's deadline covers it, and a print
  callback that calls its own session throws `StateError`: it would wait
  on the turn it runs in. A callback that never completes is ended by
  `requestTimeout` or `close`, as any turn is. Without a callback, printed
  text goes to the process's stdout and stderr on native and to the console
  on the web.
- **Close** with no turn in flight — the session idle, or only a host
  callback running — sends `Reset` and returns the worker to the pool.
  With a turn in flight it kills the worker, and the call in flight fails
  with `MontyCrashedError`. Close never throws and is idempotent.

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
  `checkoutTimeout` is set. That wait is all `checkoutTimeout` covers:
  starting a new worker is bounded by a 30-second startup deadline, and the
  session's configure turn by `requestTimeout` — three separate deadlines,
  so a checkout that waits, spawns and configures can take all three.
- Values cross the boundary encoded, so every input, host function call and
  result is copied.
- Native consumers need a worker executable, or the build-hook opt-in and
  `runMontyWorkerIfChild` (see the README's Platforms section).

# Execution model and its fault boundary

`dart_monty_core` embeds the monty interpreter **in your process**. That is a
supported topology upstream, but it differs from every first-party monty
binding, and the difference is a safety property rather than an API detail.
This page states it plainly so nobody discovers it from a crash report.

## The short version

| | crash isolation | hard preemption | notes |
|---|---|---|---|
| **FFI** (desktop, server, mobile) | **none** | **none** | interpreter runs in your process |
| **WASM** (web) | yes | yes | Web Worker; wasm traps are contained |

On FFI, a memory fault inside sandboxed Python — stack-overflow abort,
allocator abort, or any segfault in the native crate — **terminates the host
application**, not just the sandbox.

## Why upstream does it differently

A Rust process cannot be made crash-proof against memory errors; those aborts
cannot be caught. Upstream's answer is to run the interpreter only in worker
subprocesses, so a crash kills a worker and the parent replaces it. That is the
entire purpose of the `monty-pool` crate, which is new in monty v0.0.19:

> Monty executes untrusted Python, and a Monty process can never be made fully
> crash-proof against memory errors (stack overflow aborts, allocator aborts).
> This crate isolates those crashes by running the interpreter **only in worker
> subprocesses** […] a crashed worker kills only itself, the pool detects the
> death and replaces the worker, and the parent process is never at risk.
>
> — `crates/monty-pool/README.md:6-10`

Both first-party bindings follow that rule and keep the interpreter out of the
host binary entirely: neither `pydantic_monty` nor `@pydantic/monty` depends on
the `monty` crate (`crates/monty-python/Cargo.toml:24-27`,
`crates/monty-js/Cargo.toml:22-24`). `monty-pool` also runs a watchdog thread
that kills a worker whose turn exceeds its deadline
(`crates/monty-pool/src/watchdog.rs:1-2`) — hard preemption you cannot perform
inside a process.

In-process embedding is nonetheless a documented, supported topology: it is what
`monty-runtime` (the `monty` CLI), `monty-datatest`, `monty-bench` and `fuzz`
all do, and what `crates/monty/README.md:11` advertises. We are not doing
something unsupported; we are the only *binding* that does it.

## Why the web backend is not affected

Two independent reasons, either of which would be sufficient:

- A **wasm trap** (stack exhaustion, out-of-bounds) is caught by the wasm
  runtime and surfaces as an error. It is not a process abort.
- The module runs in a **Web Worker**, whose `terminate()` is a real hard-kill.
  This is the same arrangement upstream ships for browsers
  (`crates/monty-wasm-runtime`).

## What is already handled on FFI

Resource limits are enforced *by the engine*, not by killing anything, so the
ordinary runaway cases are covered without a process boundary:

```dart
await Monty(code).run(
  limits: const MontyLimits(memoryBytes: 32 << 20, stackDepth: 200, timeoutMs: 5000),
);
```

`timeoutMs` stops a non-terminating loop, `stackDepth` turns runaway recursion
into `RecursionError`, and `memoryBytes` into `MemoryError`. What limits cannot
cover is a genuine memory fault in native code — by definition there is no
cooperative point at which to raise.

## Why Dart isolates are not a fix

Isolates have separate heaps but share **one OS process**, so a native abort
takes down every isolate along with the host. They are a concurrency boundary,
not a fault boundary.

They also do not give preemption here: an isolate blocked in a synchronous FFI
call cannot be killed, because `Isolate.kill` only takes effect at a Dart
safepoint and a native call does not reach one until it returns.

Running the sandbox in an isolate is still worthwhile to keep work off the
Flutter UI thread. It is not a safety measure, and should not be described as
one.

## If you need isolation on FFI today

Run `dart_monty_core` in a **separate OS process** you control and speak to it
over your own IPC, so a crash takes down that process instead of your app. This
is what upstream's pool does, one layer up.

Tracked for a first-class answer in
[core#144](https://github.com/runyaga/dart_monty_core/issues/144) — a pool /
isolated-execution mode.

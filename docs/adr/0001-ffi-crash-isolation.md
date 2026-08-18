# ADR 0001 — Crash isolation for the FFI backend

- **Status:** accepted
- **Date:** 2026-08-16
- **Applies to:** `dart_monty_core` 0.19.0
- **Supersedes:** nothing. **Informed by:** `~/dev/plans/dmc-isolation/DESIGN.md`
  (nine review passes), `~/dev/plans/dart-monty-core-0.19-release.md` (M1).

---

## The defect, measured

With the interpreter in the caller's own process, this sandboxed Python

```python
def f(n):
    return f(n + 1)
f(0)
```

run with `MontyLimits(stackDepth: 100000)` **kills the Dart host process**:
exit `132` — SIGILL from Rust's `abort` — on macOS arm64, 2026-08-16.

No Dart exception is thrown. `MontyResult.error` is never populated.
`catch_ffi_panic` (`native/src/lib.rs:34`) does not fire, because it guards Rust
*panics* and a stack overflow is an abort. Every session in the process dies,
including sessions belonging to unrelated callers.

The default `stackDepth` of 1000 (`base_monty_platform.dart:81`) turns ordinary
recursion into a clean `RecursionError`. The defect is reachable because the
limit is caller-supplied and the interpreter cannot check a bound below its own
stack frame. **A sandbox whose escape hatch is "do not raise the limit we let
you raise" is not a sandbox.**

This is asserted, red-first, in `test/integration/ffi_pool_spike_test.dart`,
group *"the defect this exists to contain"*.

## Decision

**Option A — Dart owns the pool.** The interpreter runs in a **worker process**
that Dart spawns, addresses over a length-prefixed JSON frame channel, and can
lose. The parent holds the deadline and preempts with `SIGKILL`.

```
   MontyPool                          pure Dart — one implementation
       │  checkout / watchdog / respawn
       ▼
   MontyRepl (.withBindings)
       │
   RemoteReplBindings implements ReplBindings
       │
   MontyWorkerChannel  (abstract)
   ┌───┴────────────────────┐
ProcessChannel        WorkerChannel
(dart:io, stdio)      (JS Worker)
```

Only the **channel** is conditionally imported. The pool — checkout,
elasticity, recycling, the watchdog, the error taxonomy — is pure Dart and is
written once for FFI, dart2js and dart2wasm alike. That constraint is binding,
not incidental: see *Backend coverage* below.

### Pooling is opt-in, and the in-process path is unchanged

**This decision adds a way to run the interpreter. It removes none.**
`MontyRepl`'s and `Monty`'s existing constructors keep running the interpreter
in the caller's own process, exactly as they do today. Isolation arrives as a
separate library — `package:dart_monty_core/pool.dart` — and a consumer who
never imports it is unaffected.

Stated explicitly because the opposite reading has a real victim. Mobile
consumers compile the crate and wire it into their own Flutter plugin
(`AGENTS.md:28`), and **iOS forbids spawning a child process at all**. An ADR
that read as *"the FFI backend now runs in a worker"* would be describing a
change that leaves those consumers with nothing to call. It does not: they keep
the in-process path, they do not get isolation, and — per *Backend coverage*
below — the API has to say so rather than pretend.

The cost of opt-in is stated plainly too: **the default stays unisolated.** A
caller who never reads this document gets today's behaviour, including today's
defect. Making isolation the default is a separate decision, it is not this
one, and it should not be made until the pool has shipped and been measured in
someone's application.

## Why not the others

### B — link `monty-pool`, let Rust fork · **rejected**

Upstream contains crashes by running the interpreter only in worker
subprocesses (`crates/monty-pool/README.md`). Linking that crate puts Rust-side
`fork`/`exec` **underneath Dart FFI**, where Rust's reaper and Dart's own
SIGCHLD handling both want the children. The repo has a standing rule against
exactly this.

Rejecting B is not a claim that the race is unfixable — it is that A obtains the
same properties without needing the race disproved. **The spike does not test B**
and no result here should be read as evidence about it.

What the spike *does* settle is the A-shaped question, which had to be answered
before A could be chosen: with Dart as the only spawner, does the parent's own
child-reaping interfere with the worker, or the worker with it? Measured — 30
`Process.run` children reaped while 30 interpreter round trips are in flight,
then again with the worker crashing mid-flight. Every unrelated child kept its
exit status, every round trip returned its value, and the crash still surfaced
as a typed `MontyWorkerCrashed` rather than a hang. There is exactly one reaper
and it is Dart's.

### C — run the wasm module in a native wasm runtime · **rejected, but not for the reason the plan gave**

The release plan rejected C on the grounds that *"wasmtime cannot even parse
`dart2wasm --standalone` output"*. **That reason does not apply and has been
retracted.** It conflates two different artifacts. The module C would run is
`lib/assets/dart_monty_core_native.wasm` — Rust compiled for `wasm32-wasip1`,
a valid WASI module. Verified 2026-08-16:

```
$ wasmtime run --invoke monty_wire_format_version \
    lib/assets/dart_monty_core_native.wasm
4
```

wasmtime 44.0.1 loads it and calls into it. **C is technically feasible.** It is
rejected on cost and scope:

- It changes what the FFI backend *is*. Today "FFI" means a native dylib
  compiled for the host triple; under C it would mean a wasm sandbox on native,
  which is the trade the **existing WASM backend already offers** to consumers
  who want it. Shipping it twice under two names helps nobody.
- It adds a wasm runtime as a build-from-source dependency for every consumer.
  `hook/build.dart` already asks for Rust and a C linker; embedding wasmtime is
  a materially larger ask.
- It buys nothing on the web, where the module already runs in a Worker. The
  real web gap is **per-session** isolation (one REPL's timeout currently kills
  every REPL sharing the Worker, and a crashed Worker is never respawned), and
  that is pool policy, not runtime choice — A fixes it, C does not touch it.
- The performance cost of interpreting under wasm on native is **unmeasured
  here**, and is stated as an open cost rather than a settled one.

If the dependency calculus changes, C should be reconsidered on these grounds —
not dismissed with the parse claim, which is false.

### D — document, don't isolate · **rejected**

Contradicts the owner's decision. The substantive objection to D — that the
crash is only reachable by a caller who deliberately raised `stackDepth` to 100×
the default, and is therefore self-inflicted — fails on what a limit *means*:

**Raising a limit is a request for a more permissive sandbox, not a waiver of
containment.** A caller who sets `stackDepth: 100000` is asking to allow deeper
recursion by untrusted code. They are not asking for untrusted code to be able
to destroy the host process, and nothing in the API suggests that is what they
bought. An untrusted script that terminates its host with an uncatchable signal
is a total loss of availability, and shipping that as a documented property of a
*sandboxing* library is not a proportionate response — it is the
vulnerability, restated.

(This reasoning is adopted from the adversarial pass, which put it better than
the original draft did. The draft asserted that such a caller "believes they are
still sandboxed", which named no mechanism and was rhetoric rather than an
argument.)

## What was measured

`tool/pool_bench.dart`, macOS arm64, 18 cores, 200 samples per figure, medians.
Upstream publishes no equivalent numbers, which is why this exists.

| | JIT worker (`dart run`) | AOT worker (`dart build cli`) |
|---|---|---|
| prewarm (spawn → ready) | **439.5 ms** | **12.3 ms** |
| empty round trip (`ping`) | 0.084 ms | **0.050 ms** |
| `2 + 2` out of process | 0.107 ms | 0.056 ms |
| `2 + 2` in process (FFI) | 0.016 ms | 0.016 ms |
| **IPC tax on a trivial call** | 0.091 ms | **0.040 ms** |

Read them this way: the tax is **40 µs per call** on the shipping (AOT) path.
That is the floor this design adds to every interpreter call, and it is small
against anything a caller would actually run. Prewarm is 12 ms and is paid once
per worker, not once per call — which is the entire reason the pool keeps
workers alive rather than spawning per execution.

**A is affordable.** That was the open question the measurement existed to
close.

## Consequences

### The value wire is unchanged

`WIRE_FORMAT_VERSION` is **4** (`native/src/convert.rs:50`) and stays 4. Values
cross the FFI boundary inside the worker in exactly the encoding they do today.

That claim is **enforced, not merely stated**: `tool/check_wire_version.sh` runs
in the gate and in CI and fails if the crate's constant and Dart's
`expectedWireFormatVersion` disagree. The check script is the artifact; this
paragraph is a pointer to it. Note that none of the files this ADR adds can be
used to verify the claim — `worker_protocol.dart` contains no value encoding at
all — so a reader checking it should open `native/src/convert.rs:50` and the
script, not the pool.

What is new is **transport framing** — a 4-byte little-endian length followed by
UTF-8 JSON (`lib/src/pool/frame_codec.dart`) — plus a typed message layer
(`lib/src/pool/worker_protocol.dart`). These are independent of the value wire
and must not be conflated with it: bumping one says nothing about the other.
The framing is declared here because the gate asks for it, not because anything
about value encoding moved.

### Hard preemption is preserved

Upstream's parent-side `request_timeout` / `PoolError::Timeout` is the only
preemption that needs no cooperation from the target. `MontyLimits.timeoutMs` is
polled at interpreter checkpoints, so it cannot stop code that never reaches
one. The parent arms a `Timer`, and on expiry sends `SIGKILL` — measured ending
a `while True: pass` with the child at exit `-9`.

This also closes the M5 "no default wall-clock timeout" defect from outside,
in a way in-VM limits structurally cannot.

**The pid identity is load-bearing and is asserted.** If a launcher ever forked
the real interpreter into a grandchild, `Process.kill` would land on the
launcher while the interpreter kept running, and every timeout test would still
pass. The spike asserts `worker.pid == worker.osPid` — the process the parent
can signal *is* the process running the interpreter. If that assertion ever
fails, the pool must kill the process **group**, not the process.

### Hang detection is not crash containment

Worth restating because conflating them is the likeliest way to ship a false
claim: a sandboxed infinite loop never traps, never aborts, and fires no error
handler on any backend. Respawn-on-crash covers traps and aborts. Only the
watchdog covers hangs. They are different mechanisms and the README claim must
not merge them.

### Backend coverage

The pool API must work on **FFI, dart2js and dart2wasm** — it is the isolation
*contract*, not the native implementation of one. Consequences:

- Everything backend-neutral lives in `lib/src/pool/` as pure Dart with no
  `dart:io`, no `dart:ffi`, no JS interop. `lib/` keeps its **zero `dart:io`**
  property; the `dart.library.io` arm arrives with `pool.dart` in M2, together
  with a CI grep pinning the invariant.
- The framing and protocol are tested on **all three targets** —
  `test/unit/frame_codec_test.dart`, 14 tests green on VM, dart2js and
  dart2wasm. This is not box-ticking: dart2js coerces bitwise operands to 32-bit
  signed, and the subject is a 32-bit length prefix. A length misread as
  negative would silently mean "not enough bytes yet" and hang the channel
  rather than fail it, so `0x80000000` is asserted to be read unsigned.
- `ffi_pool_spike_test.dart` has **no `wasm_` twin, deliberately**. Process
  isolation is what it measures and the web has no processes; the web isolates
  with Workers, reached through the other channel. Anything added to it that is
  not process-specific belongs in the codec test instead, where all three
  compilers see it.
- Where a target cannot deliver isolation at all — iOS/Android emit no FFI asset
  (`hook/build.dart:21-22`), and `dart compile exe` cannot resolve native assets
  — the API must **say so** rather than degrade quietly. A safety feature the
  caller wrongly believes in is worse than none.

### A constraint on the dev spawn path, found by building it

Two facts the prior design did not have, both measured:

1. **`dart run` writes to the child's stdout before the child's `main()`.** It
   emits `Running build hooks...`, so a parent reading length prefixes from byte
   0 reads `"Runn"` as a 1,852,796,754-byte frame. The child cannot suppress it.
   The worker therefore emits a marker (`frameStreamMagic`) and the parent
   discards everything up to it **once**, at handshake. After that the stream is
   exact and a bad prefix is fatal — never a cue to resynchronise, which is a
   hunt whoever corrupted the stream would control.

2. **Concurrent `dart run` invocations race** on the shared
   `.dart_tool/lib/libdart_monty_core_native.dylib` staging: measured as
   `install_name_tool: cannot rename …` and a worker exiting 1 before its
   handshake. The spike keeps its spawns sequential by living in one file.
   **The shipping path is not exposed to either problem** — an AOT worker built
   with `dart build cli` stages nothing and prints nothing — which is a further
   argument for making AOT the default and `dart run` the dev convenience.

## What the spike proves, and what it does not

Proved, in CI (`test/integration/ffi_pool_spike_test.dart`, 10 tests):

- in-process, the overflow kills the host (the red half);
- out of process, the same overflow kills only the worker, and the parent
  keeps running;
- the pool can respawn and serve the next request after a crash;
- a request issued after the crash fails as a typed `MontyWorkerCrashed`
  rather than hanging;
- a Python exception is a **result**, not a worker failure — the session
  survives it, so the pool must not recycle a worker over a user's typo;
- an unserviceable request is answered, not fatal;
- the parent-side deadline SIGKILLs a hang the in-VM limits cannot see;
- Dart's own child-reaping and the worker do not interfere, in either
  direction, including while the worker is dying.

**Not** proved, and not claimed:

- Nothing here is evidence about option B's SIGCHLD behaviour.
- The full `ReplBindings` proxy is not built. The spike carries `create`,
  `feedRun`, `dispose`, `ping` and `shutdown` — enough to hold a real session
  and therefore a real crash. The remaining 10 methods, the `setExtFns`
  coalescing rules, and value marshalling through `MontyValue.encodeForWire`
  are M2.
- `WorkerRunResult.value` is a **rendered string**, not a decoded value. Named
  and documented as such so it cannot be mistaken for the real proxy.
- The web channel is unbuilt; the per-session Worker defects it fixes are still
  live.
- Distribution (bundling the worker beside a Flutter desktop app) is designed
  but not shipped.
- Crash containment was exercised on the AOT worker by hand (exit `-4`, parent
  alive) but only the JIT path runs in CI.

## Next

M2 builds `package:dart_monty_core/pool.dart`: `MontyPool`, `MontyIsolation`,
`checkout`/`withCheckout`, `RemoteReplBindings`, both channels, and the
`dart:io`-containment CI grep. The web channel comes with it, because the pool
is not FFI-only and must not be built as though it were.

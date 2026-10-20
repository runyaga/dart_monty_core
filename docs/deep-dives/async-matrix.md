# Host functions and `async`

How a Python call to a host function behaves depends on two things: how the
host answers it, and whether Python `await`s it. This page is the reference
for each combination, on the public API. The behaviour is the same on native
and on the web.

## The two ways to answer

1. **`feedRun(code, externalLookup: {...})`.** The session runs the host
   function (a `MontyHostFunction`) and awaits its `Future` Dart-side
   before Python resumes. To Python the call is synchronous: it returns a
   plain value. A function whose `fn` is wrapped in `coroutine(...)` is an
   `async def` function instead: each
   call is an awaitable that Python awaits, and the session settles it when
   the Dart future completes.
2. **`feedStart(code)` and the snapshots.** The caller answers each
   `FunctionSnapshot` itself. `resume(ExternalReturnValue(v))` or
   `resume(ExternalException(type, message))` settles the call at once;
   `resume(const ExternalFuture())` hands Python a pending future instead,
   which the caller settles later from a `FutureSnapshot`.

## The matrix

| | `externalLookup` (`feedRun`) | `coroutine(fn)` in `externalLookup` | snapshot, settled at once | snapshot, `ExternalFuture` |
|---|---|---|---|---|
| bare call `fn(x)` | the value | an awaitable | the value | an awaitable (`type(x).__name__` is `'coroutine'`) |
| `await fn(x)` | `TypeError: '<type>' object can't be awaited` | the value | the same `TypeError` | the value, once settled |
| `asyncio.gather(fn(a), fn(b))` | `TypeError` | the calls run at once; results in argument order | `TypeError` | all calls are made before any is settled; results in argument order |
| exception from the host | raised at the call; `try`/`except` catches it | raised at the `await` | the same | raised at the `await`; `try`/`except` catches it |

A synchronous answer is not awaitable, so `await` on it fails the way it does
in CPython. A future answer lets several host calls be in flight at once:
under `asyncio.gather`, each call suspends with a `FunctionSnapshot`, and
once every task is blocked a `FutureSnapshot` lists the pending call ids.

## The futures loop

<!-- This block includes embedded Python imports and requires caller-provided session state. -->
```dart skip
Future<MontySnapshot> answer(MontySnapshot snapshot) async {
  final keys = <int, String>{};
  while (true) {
    switch (snapshot) {
      case MontyComplete():
        return snapshot;
      case FunctionSnapshot s:
        keys[s.callId] = (s.args[0] as MontyString).value;
        snapshot = await s.resume(const ExternalFuture());
      case FutureSnapshot s:
        snapshot = await s.resume({
          for (final id in s.pendingCallIds)
            id: keys[id] == 'bad'
                ? const ExternalException('ValueError', 'bad key')
                : ExternalReturnValue(MontyString('v-${keys[id]}')),
        });
      case NameLookupSnapshot s:
        snapshot = await s.resume();
    }
  }
}

final done = await answer(await session.feedStart('''
import asyncio
async def main():
    return await asyncio.gather(fetch("a"), fetch("b"))
await main()
''')) as MontyComplete;
print(done.output); // MontyList: ['v-a', 'v-b']
```

`FutureSnapshot.resume` may settle some of the pending calls; the rest are
reported again. An `ExternalException` there raises inside Python at the
`await`, where `try`/`except` catches it like any other exception.

## The eager await

A coroutine call the sandbox awaits with nothing else to run — a lone
`await fn(x)`, no sibling task — is marked by the sandbox, and the
`FunctionSnapshot` reports it: `allowEagerAwait` is true. The host may then
await the Dart future in place and deliver the settled result at once,
through the same futures answer that settles pending ones. `resumeAuto()`
does so, and `feedRun` answers through the same code, so the call costs one
suspension and no `FutureSnapshot` follows for it: the direct-await
optimization.

Any other coroutine call — under `asyncio.gather`, or with sibling tasks
still running — is answered with a pending future instead
(`resume(ExternalFuture())` on the manual path): Python receives the future,
and its result is delivered once every task is blocked, through a
`FutureSnapshot`. That is what lets `asyncio.gather` run several host
coroutines at once.

Of the OS calls only the two async sleeps, `asyncio.sleep` and
`system.async_sleep`, accept a future answer; the eager mark on any other
OS call is dropped. `feedRun` waits `system.async_sleep` itself, capped by
the OS policy, and delivers it eagerly when the sandbox awaits it alone.

## Sleeps

`feedRun` waits out system sleeps, cut to the OS policy's system-sleep maximum
(10 s by default, set with `OsPolicy`). The system-sleep calls are
`system.sleep` and `system.async_sleep`; the async one waits through the
futures protocol, so sibling tasks run meanwhile, as an `asyncio.sleep` does.
A snapshot `resumeAuto()` does not wait them: it routes both, by those names,
to the mounts and the OS handler to answer. A session's total sleep is
bounded by `ResourceLimits.maxTotalSleep`.

## Where it is tested

- `test/unit/worker/monty_snapshot_test.dart` and
  `test/integration/worker/monty_snapshot_io_test.dart`: snapshots and their
  resumes, on the web and native;
- the upstream corpus (`test/corpus/`), whose async cases run through the
  same futures protocol.

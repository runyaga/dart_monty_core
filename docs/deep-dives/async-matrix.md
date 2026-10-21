# Host functions and `async`

How a Python call to a host function behaves depends on two things: how the
host answers it, and whether Python `await`s it. This page is the reference
for each combination, on the public API. The behaviour is the same on native
and on the web.

## Host code supplies two answer paths

[`MontySession.feedRun`](../../lib/src/worker/monty_session.dart) drives host
answers automatically. [`MontySession.feedStart`](../../lib/src/worker/monty_session.dart)
returns snapshots for the caller to answer.

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

[`FutureSnapshot.resume`](../../lib/src/worker/monty_snapshot.dart) defines
partial settlement and exception delivery.

## Coroutine answers

[`FunctionSnapshot.allowEagerAwait`](../../lib/src/worker/monty_snapshot.dart)
and [`coroutine`](../../lib/src/worker/host_answers.dart) define coroutine
settlement.

## Sleeps

[`MontySession.feedRun`](../../lib/src/worker/monty_session.dart),
[`MontySession.feedStart`](../../lib/src/worker/monty_session.dart), and
[`FunctionSnapshot.resumeAuto`](../../lib/src/worker/monty_snapshot.dart) define
system-sleep handling. [`ResourceLimits.maxTotalSleep`](../../lib/src/worker/resource_limits.dart)
defines the session sleep budget.

## Where it is tested

- `test/unit/worker/monty_snapshot_test.dart` and
  `test/integration/worker/monty_snapshot_io_test.dart`: snapshots and their
  resumes on the web and native
- the upstream corpus (`test/corpus/`), whose async cases run through the
  same futures protocol.

// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 06 — Async host calls and name lookups
//
// Two more kinds of suspension a feedStart loop meets:
//
//  - FutureSnapshot. Answering a host call with ExternalFuture gives the
//    sandbox a pending future instead of a value, so its other tasks run on
//    (asyncio.gather over several calls). When every task waits on pending
//    futures the feed suspends with their call ids; resume() settles some
//    or all of them, by call id.
//
//  - NameLookupSnapshot. A global name the code never defined suspends the
//    feed; resume(value:) binds it, and resume() leaves it undefined, so
//    the sandbox raises NameError.
//
// Covers: ExternalFuture, FutureSnapshot.pendingCallIds, FutureSnapshot.resume
//         with ExternalReturnValue and ExternalException,
//         FunctionSnapshot.callId, NameLookupSnapshot.
//
// Run: dart run example/06_futures_and_lookups.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await _futures(session);
      await _lookups(session);
    }),
  );
}

// ── Pending futures ──────────────────────────────────────────────────────────
Future<void> _futures(MontySession session) async {
  print('\n── futures ──');

  var snapshot = await session.feedStart('''
import asyncio


async def safe(n):
    try:
        return await fetch(n)
    except ValueError as e:
        return f"error: {e}"

await asyncio.gather(safe(1), safe(2), safe(3))
''');
  // The call each pending future belongs to, by call id.
  final arguments = <int, int>{};
  var rounds = 0;
  while (snapshot is! MontyComplete) {
    switch (snapshot) {
      case FunctionSnapshot():
        arguments[snapshot.callId] = (snapshot.args.single as MontyInt).value;
        print('fetch(${snapshot.args.single}) -> pending #${snapshot.callId}');
        snapshot = await snapshot.resume(const ExternalFuture());
      case FutureSnapshot(:final pendingCallIds):
        rounds++;
        print('waiting on $pendingCallIds');
        // Settle every pending call: the odd ones with a value, the even one
        // with an exception, which `safe` catches.
        snapshot = await snapshot.resume({
          for (final id in pendingCallIds)
            id: arguments[id]!.isOdd
                ? ExternalReturnValue(MontyInt(arguments[id]! * 10))
                : const ExternalException('ValueError', 'even'),
        });
      case NameLookupSnapshot():
        throw StateError('unexpected lookup of ${snapshot.variableName}');
      case MontyComplete():
        break;
    }
  }
  final output = snapshot.output;
  print('results: ${output.dartValue}');
  _check(rounds == 1, 'one futures round');
  _check(output is MontyList && output.items.length == 3, 'three results');
  final items = (output as MontyList).items;
  _check(items[0] == const MontyInt(10), 'fetch(1)');
  _check(items[1] == const MontyString('error: even'), 'fetch(2) raised');
  _check(items[2] == const MontyInt(30), 'fetch(3)');
}

// ── Name lookups ─────────────────────────────────────────────────────────────
Future<void> _lookups(MontySession session) async {
  print('\n── name lookups ──');

  const config = {'RATE': MontyFloat(0.25)};

  var snapshot = await session.feedStart('''
try:
    extra = BONUS
except NameError:
    extra = 0
price = 120 * (1 - RATE) + extra
price
''');
  while (snapshot is NameLookupSnapshot) {
    final lookup = snapshot;
    final value = config[lookup.variableName];
    print('lookup ${lookup.variableName} -> ${value ?? 'undefined'}');
    snapshot = value == null
        ? await lookup.resume()
        : await lookup.resume(value: value);
  }
  final price = (snapshot as MontyComplete).output;
  print('price: $price');
  _check(price == const MontyFloat(90), 'price');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}

// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 04 — Driving a feed by hand: feedStart and snapshots
//
// feedRun answers host calls itself. feedStart instead returns at each
// suspension as a MontySnapshot for the caller to answer, and at the end as
// MontyComplete. Each host function call and each OS call is a
// FunctionSnapshot; resume() answers it and runs to the next suspension.
//
// Covers: feedStart, MontyComplete, FunctionSnapshot (functionName, args,
//         kwargs, isOsFunction, position), resume with ExternalReturnValue
//         and ExternalException, resumeNotHandled, resumeAuto.
//
// Run: dart run example/04_session.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await _manualLoop(session);
      await _exceptions(session);
      await _osCalls(session);
      await _auto(session);
    }),
  );
}

// ── Manual loop ──────────────────────────────────────────────────────────────
Future<void> _manualLoop(MontySession session) async {
  print('\n── manual loop ──');

  var snapshot = await session.feedStart('''
a = fetch("alpha")
b = fetch("beta", scale=10)
a + b
''');
  final calls = <String>[];
  while (snapshot is FunctionSnapshot) {
    final call = snapshot;
    final key = (call.args.single as MontyString).value;
    final scale = call.kwargs['scale'];
    calls.add(
      '${call.functionName}($key) at bytes '
      '${call.position.start}-${call.position.end}',
    );
    final value = key.length * (scale is MontyInt ? scale.value : 1);
    snapshot = await call.resume(ExternalReturnValue(MontyInt(value)));
  }
  calls.forEach(print);
  final complete = snapshot as MontyComplete;
  print('result: ${complete.output}');
  _check(complete.output == const MontyInt(5 + 40), 'manual loop');
}

// ── Answering with an exception ──────────────────────────────────────────────
Future<void> _exceptions(MontySession session) async {
  print('\n── resume with ExternalException ──');

  final snapshot = await session.feedStart('''
try:
    load("config")
    out = "loaded"
except FileNotFoundError as e:
    out = f"fallback ({e})"
out
''');
  final call = snapshot as FunctionSnapshot;
  final done = await call.resume(
    const ExternalException('FileNotFoundError', 'no such config'),
  );
  final output = (done as MontyComplete).output;
  print('result: $output');
  _check(output == const MontyString('fallback (no such config)'), 'raise');
}

// ── OS calls are snapshots too ───────────────────────────────────────────────
Future<void> _osCalls(MontySession session) async {
  print('\n── os calls ──');

  var snapshot = await session.feedStart('''
import os
try:
    shell = os.getenv("SHELL")
except RuntimeError as e:
    shell = f"declined: {e}"
(os.getenv("HOME"), shell)
''');
  while (snapshot is FunctionSnapshot) {
    final call = snapshot;
    print('os call: ${call.functionName}${call.args}');
    _check(call.isOsFunction, 'isOsFunction');
    final name = (call.args.first as MontyString).value;
    snapshot = name == 'HOME'
        ? await call.resume(const ExternalReturnValue(MontyString('/sandbox')))
        // Decline: the sandbox raises the call's own default error.
        : await call.resumeNotHandled();
  }
  final output = (snapshot as MontyComplete).output;
  print('result: $output');
  _check(output is MontyTuple, 'os result');
  _check(
    (output as MontyTuple).items.first == const MontyString('/sandbox'),
    'HOME',
  );
}

// ── resumeAuto: let the session answer from externalLookup ───────────────────
Future<void> _auto(MontySession session) async {
  print('\n── resumeAuto ──');

  var snapshot = await session.feedStart(
    '[double(i) for i in range(3)]',
    externalLookup: {
      'double': MontyHostFunction(
        'double',
        (args, _) => MontyInt((args[0] as MontyInt).value * 2),
      ),
    },
  );
  var steps = 0;
  while (snapshot is FunctionSnapshot) {
    steps++;
    snapshot = await snapshot.resumeAuto();
  }
  final output = (snapshot as MontyComplete).output;
  print('$steps suspensions, result: $output');
  _check(steps == 3, 'steps');
  _check(output == MontyValue.fromDart([0, 2, 4]), 'resumeAuto');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}

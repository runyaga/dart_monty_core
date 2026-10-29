// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 16 — Stepping through a feed with byte-exact source slices
//
// A stepping debugger has to say where each suspension sits in the source the
// user wrote. SourceRange offsets count UTF-8 bytes, while Dart strings are
// UTF-16 code units, so every `é` before the cut shifts a naive slice by one.
// The script is therefore encoded once, and each snapshot's byte range is
// decoded back out of those bytes instead of the string. Step 1 slices the
// string at the byte offsets on purpose, to show the off-by-one that follows.
//
// The checks run in order and fail fast: the first mismatch is reported on
// stderr after the pool has closed, the process exits 1, and no later PASS
// line is printed.
//
// Covers: feedStart, NameLookupSnapshot (variableName, resume with a value),
//         FunctionSnapshot (functionName, args, callId, resume with
//         ExternalException and ExternalFuture), FutureSnapshot
//         (pendingCallIds, resume with ExternalReturnValue), MontyComplete,
//         SourceRange as UTF-8 offsets.
//
// Run: dart run example/16_step_debugger.dart

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

/// The script the feed runs. The accents are the point: `é` is one Dart code
/// unit but two UTF-8 bytes. Its first character is the `#` of the opening
/// comment, and it ends with exactly one newline.
const String _script = '''# étape 1: base
total = base + 10
# étape 2: bonus
try:
    bonus = fetch_bonus(total)
    note = "live"
except ValueError as err:
    bonus = 5
    note = f"fallback:{err}"
# étape 3: sauvegarde
saved = await commit(total + bonus)
(total, bonus, note, saved)
''';

/// The script as the worker measures it: UTF-8 bytes, the units SourceRange
/// offsets count.
final List<int> _scriptBytes = utf8.encode(_script);

Future<void> main() async {
  try {
    await Monty.withPool(
      (monty) => monty.withSession((session) => _walk(session)),
    );
  } on StateError catch (failure) {
    // Both scopes have unwound by now: the session, then the pool, are closed.
    stderr.writeln('$failure');
    await stdout.flush();
    await stderr.flush();
    exit(1);
  }
  print('DEMO OK step_debugger');
}

/// Answers each suspension in turn and checks what the next one reports.
Future<void> _walk(MontySession session) async {
  final afterOne = await _stepOne(session);
  final afterTwo = await _stepTwo(afterOne);
  final (afterThree, commitCallId) = await _stepThree(afterTwo);
  final afterFour = await _stepFour(afterThree, commitCallId);
  _stepFive(afterFour);
}

/// Step 1 — a bare name the sandbox cannot resolve suspends as a lookup.
Future<MontySnapshot> _stepOne(MontySession session) async {
  final snapshot = await session.feedStart(_script);
  if (snapshot is! NameLookupSnapshot) {
    _fail('step-1-kind', snapshot.runtimeType, NameLookupSnapshot);
  }
  print('PASS step-1-kind');
  final position = snapshot.position;
  _check('step-1-name', snapshot.variableName, 'base');
  _range('step-1-bytes', position, 25, 29);
  _slice('step-1-slice', position, 25, 29, 'base');
  // The deliberate mistake: those are byte offsets, not string indices.
  _check(
    'step-1-utf16-off-by-one',
    _script.substring(position.start, position.end),
    'ase ',
  );

  return snapshot.resume(value: const MontyInt(40));
}

/// Step 2 — the same unresolved name in call position suspends as the call.
Future<MontySnapshot> _stepTwo(MontySnapshot snapshot) {
  if (snapshot is! FunctionSnapshot) {
    _fail('step-2-kind', snapshot.runtimeType, FunctionSnapshot);
  }
  print('PASS step-2-kind');
  _check('step-2-fn', snapshot.functionName, 'fetch_bonus');
  _items('step-2-arg', snapshot.args, const [MontyInt(50)]);
  _slice('step-2-slice', snapshot.position, 70, 88, 'fetch_bonus(total)');
  // The sandbox raises this inside the call, so the except branch runs.

  return snapshot.resume(const ExternalException('ValueError', 'offline'));
}

/// Step 3 — a top-level await's own call, answered with a pending future.
/// The call id it is settled by comes back with the next snapshot.
Future<(MontySnapshot, int)> _stepThree(MontySnapshot snapshot) async {
  if (snapshot is! FunctionSnapshot) {
    _fail('step-3-kind', snapshot.runtimeType, FunctionSnapshot);
  }
  print('PASS step-3-kind');
  _check('step-3-fn', snapshot.functionName, 'commit');
  _items('step-3-arg', snapshot.args, const [MontyInt(55)]);
  _slice('step-3-slice', snapshot.position, 213, 234, 'commit(total + bonus)');
  final pending = await snapshot.resume(const ExternalFuture());

  return (pending, snapshot.callId);
}

/// Step 4 — every task now waits on that one future, and the position covers
/// the whole await expression rather than the call.
Future<MontySnapshot> _stepFour(MontySnapshot snapshot, int commitCallId) {
  if (snapshot is! FutureSnapshot) {
    _fail('step-4-kind', snapshot.runtimeType, FutureSnapshot);
  }
  print('PASS step-4-kind');
  _items('step-4-pending', snapshot.pendingCallIds, [commitCallId]);
  _slice(
    'step-4-slice',
    snapshot.position,
    207,
    234,
    'await commit(total + bonus)',
  );

  return snapshot.resume({
    commitCallId: const ExternalReturnValue(MontyString('ok:55')),
  });
}

/// Step 5 — the feed ends with the tuple its last expression built.
void _stepFive(MontySnapshot snapshot) {
  if (snapshot is! MontyComplete) {
    _fail('complete-kind', snapshot.runtimeType, MontyComplete);
  }
  print('PASS complete-kind');
  final output = snapshot.output;
  if (output is! MontyTuple) {
    _fail('complete-output', output.runtimeType, MontyTuple);
  }
  _items('complete-output', output.items, const [
    MontyInt(50),
    MontyInt(5),
    MontyString('fallback:offline'),
    MontyString('ok:55'),
  ]);
}

/// Prints `PASS [label]` once [actual] equals [expected], else fails the demo.
void _check(String label, Object? actual, Object? expected) {
  if (actual != expected) {
    _fail(label, actual, expected);
  }
  print('PASS $label');
}

/// Prints `PASS [label]` once [actual] holds exactly [expected], in order.
/// Dart lists compare by identity, so the two are walked side by side.
void _items<T>(String label, List<T> actual, List<T> expected) {
  final expectedValues = expected.iterator;
  final same =
      actual.length == expected.length &&
      actual.every(
        (value) => expectedValues.moveNext() && expectedValues.current == value,
      );
  if (!same) {
    _fail(label, actual, expected);
  }
  print('PASS $label');
}

/// Prints `PASS [label]` once [position] covers the UTF-8 byte offsets
/// [start]..[end].
void _range(String label, SourceRange position, int start, int end) {
  if (!_covers(position, start, end)) {
    _fail(label, position, 'bytes $start..$end');
  }
  print('PASS $label');
}

/// Prints `PASS [label]` once [position] covers [start]..[end] and that byte
/// slice of the script decodes to [expected]: both halves share one line.
void _slice(
  String label,
  SourceRange position,
  int start,
  int end,
  String expected,
) {
  if (!_covers(position, start, end)) {
    _fail('$label (byte range)', position, 'bytes $start..$end');
  }
  _check(
    label,
    utf8.decode(_scriptBytes.sublist(position.start, position.end)),
    expected,
  );
}

/// Whether [position] covers exactly the UTF-8 byte offsets [start]..[end].
bool _covers(SourceRange position, int start, int end) =>
    position.start == start && position.end == end;

/// Ends the demo at the first check that did not hold. The message reaches
/// stderr after the session and the pool have both closed.
Never _fail(String label, Object? actual, Object? expected) {
  throw StateError(
    'FAIL $label\n'
    '  expected: $expected\n'
    '  actual:   $actual',
  );
}

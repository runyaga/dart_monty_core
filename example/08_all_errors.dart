// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 08 — Errors
//
// Every failure of the sandbox is a MontyError, a sealed class:
//
//  MontyError (sealed)
//   ├── MontySyntaxError  — the code did not parse; nothing ran
//   ├── MontyRuntimeError — Python raised an exception the code did not
//   │                       catch (resource limits arrive this way too)
//   ├── MontyTypingError  — a type-checking session rejected the code
//   └── MontyCrashedError — the worker is gone, and the session with it
//
// The first three leave the session usable. Each carries the inner Python
// exception as `exception` (a MontyExceptionValue); the syntax and runtime
// errors carry the traceback as Frames and render it with display().
//
// Covers: the four MontyError subtypes, exception, traceback, Frame,
//         display formats, timedOut, an exhaustive switch.
//
// Run: dart run example/08_all_errors.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool((monty) async {
    await monty.withSession(_syntaxError);
    await monty.withSession(_runtimeError);
    await monty.withSession(_typingError, typeCheck: true);
  });
  await _crashedError();
}

// ── MontySyntaxError ─────────────────────────────────────────────────────────
Future<void> _syntaxError(MontySession session) async {
  print('\n── MontySyntaxError ──');
  final error = await _expectError(session, 'def f(:\n    pass');
  _check(error is MontySyntaxError, 'syntax error type');
  print(_describe(error));
  print((error as MontySyntaxError).display('type-msg'));
}

// ── MontyRuntimeError ────────────────────────────────────────────────────────
Future<void> _runtimeError(MontySession session) async {
  print('\n── MontyRuntimeError ──');
  await session.feedRun('''
def parse(text):
    return int(text)

def load(rows):
    return [parse(r) for r in rows]
''');
  final error = await _expectError(session, 'load(["1", "two"])');
  _check(error is MontyRuntimeError, 'runtime error type');
  final runtime = error as MontyRuntimeError;
  print(_describe(runtime));
  print('frames, outermost first:');
  for (final frame in runtime.traceback) {
    print(
      '  ${frame.filename}:${frame.line}:${frame.column} '
      'in ${frame.functionName}: ${frame.sourceLine?.trim()}',
    );
  }
  _check(runtime.exception.excType == 'ValueError', 'excType');
  _check(runtime.traceback.length >= 3, 'traceback depth');
  print('--- display() ---\n${runtime.display()}');

  // The session survives: earlier definitions are still there.
  _check(
    await session.feedRun('load(["4", "5"])') == MontyValue.fromDart([4, 5]),
    'session survives',
  );
}

// ── MontyTypingError ─────────────────────────────────────────────────────────
Future<void> _typingError(MontySession session) async {
  print('\n── MontyTypingError ──');
  final error = await _expectError(session, 'x: int = "not an int"');
  _check(error is MontyTypingError, 'typing error type');
  print(_describe(error));
}

// ── MontyCrashedError ────────────────────────────────────────────────────────
// A turn that outlives the pool's requestTimeout has its worker killed.
Future<void> _crashedError() async {
  print('\n── MontyCrashedError ──');
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      final error = await _expectError(session, 'while True:\n    pass');
      _check(error is MontyCrashedError, 'crashed error type');
      final crashed = error as MontyCrashedError;
      print(_describe(crashed));
      print('timedOut=${crashed.timedOut} exitStatus=${crashed.exitStatus}');
      _check(crashed.timedOut, 'timedOut');
    }),
    requestTimeout: const Duration(milliseconds: 500),
  );
}

/// What a supervisor might do with each kind of failure.
String _describe(MontyError error) => switch (error) {
  MontySyntaxError() => 'fix the code: $error',
  MontyRuntimeError() => 'the code raised: $error',
  MontyTypingError() => 'the type check failed:\n$error',
  MontyCrashedError() => 'restart the work: $error',
};

Future<MontyError> _expectError(MontySession session, String code) async {
  try {
    await session.feedRun(code);
  } on MontyError catch (e) {
    return e;
  }
  throw StateError('no error from: $code');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}

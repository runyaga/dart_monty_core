// 08 — Complete error type coverage
//
// dart_monty_core distinguishes Python-level errors (MontyScriptError) from
// infrastructure failures (MontyPanicError, MontyCrashError, etc.).
// Pattern-match exhaustively so supervisors can react correctly.
//
// The sealed hierarchy:
//
//  MontyError (sealed)
//   ├── MontyScriptError   — Python exception (ValueError, TypeError, …)
//   │    └── MontySyntaxError — parse/compile error
//   ├── MontyPanicError    — Rust interpreter panicked
//   ├── MontyCrashError    — isolate/Worker died
//   ├── MontyDisposedError — interpreter used after dispose()
//   └── MontyResourceError — OOM, timeout, WASM trap
//
// Covers: all 5 MontyError subtypes, MontyException, MontyStackFrame,
//         result.error vs thrown error, excType, traceback traversal.
//
// Run: dart run example/08_all_errors.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  _errorInResult();      // Python errors land in result.error, not thrown
  await _syntaxError();
  await _scriptError();
  await _resourceError();
  _disposedError();
  _exhaustivePatternMatch();
}

// ── Python errors in result.error ────────────────────────────────────────────
// A Python exception does NOT throw in Dart.
// It appears in MontyResult.error while result.value is MontyNone.
void _errorInResult() {
  print('\n── error in result (no throw) ──');
  Monty.exec('1 / 0').then((r) {
    print('isError: ${r.isError}');
    if (r.error != null) {
      final e = r.error!;
      print('excType:  ${e.excType}');   // ZeroDivisionError
      print('message:  ${e.message}');
      print('line:     ${e.lineNumber}');
      print('value:    ${r.value}');     // MontyNone
    }
  });
}

// ── MontySyntaxError ──────────────────────────────────────────────────────────
// Subtype of MontyScriptError; thrown when code fails to parse or compile.
Future<void> _syntaxError() async {
  print('\n── MontySyntaxError ──');
  try {
    await Monty.exec('def broken(:');
  } on MontySyntaxError catch (e) {
    print('syntax error!');
    print('  message:  ${e.message}');
    print('  excType:  ${e.excType}');
    _printException(e.exception);
  }
}

// ── MontyScriptError ──────────────────────────────────────────────────────────
// Thrown by Monty.exec / MontyRepl.feed when Python raises and doesn't catch.
// result.error is preferred for session/repl — the REPL survives the error.
Future<void> _scriptError() async {
  print('\n── MontyScriptError (thrown + traceback) ──');

  // When code raises an unhandled exception in a one-shot context, it throws.
  // But with Monty/MontySession/MontyRepl the error lands in result.error —
  // the session survives and you can keep running code.
  try {
    // Force a throw by creating a fresh exec that raises.
    final repl = MontyRepl();
    await repl.feed('''
def outer():
    inner()

def inner():
    raise ValueError("deep error")

outer()
''');
    await repl.dispose();
  } on MontyScriptError catch (e) {
    print('script error!');
    print('  excType:  ${e.excType}');
    print('  message:  ${e.message}');
    _printException(e.exception);
  }

  // Prefer reading result.error in sessions so the interpreter survives.
  final monty = Monty();
  final r = await monty.run('raise TypeError("type error")');
  if (r.error != null) {
    print('session survived: ${r.error!.excType} — ${r.error!.message}');
    // Session is still alive — we can keep running.
    final r2 = await monty.run('1 + 1');
    print('next call works: ${r2.value}');
  }
  monty.dispose();
}

// ── MontyResourceError ────────────────────────────────────────────────────────
// Thrown on OOM, execution timeout, WASM trap, or stack overflow.
Future<void> _resourceError() async {
  print('\n── MontyResourceError (timeout) ──');
  try {
    await Monty.exec(
      'while True: pass', // infinite loop
      limits: MontyLimits(timeoutMs: 200),
    );
  } on MontyResourceError catch (e) {
    print('resource error: ${e.message}');
  }
}

// ── MontyDisposedError ────────────────────────────────────────────────────────
// Thrown when you use an interpreter after calling dispose().
void _disposedError() {
  print('\n── MontyDisposedError ──');
  final monty = Monty();
  monty.dispose();
  monty.run('1 + 1').then((_) {
    print('should not reach here');
  }).catchError((Object e) {
    if (e is MontyDisposedError) {
      print('disposed error: ${e.message}');
    }
  });
}

// ── Exhaustive supervisor pattern match ───────────────────────────────────────
// In a supervisor/retry loop, match all error types so you can react correctly.
void _exhaustivePatternMatch() {
  print('\n── exhaustive error matching ──');

  void handleError(MontyError e) {
    switch (e) {
      case MontySyntaxError():
        print('syntax: fix the code — do NOT retry');

      case MontyScriptError(:final excType):
        print('script ($excType): application error — supervisor handles');

      case MontyPanicError():
        // The Rust interpreter panicked — likely a bug. Apply backoff.
        print('panic: Rust bug — backoff and restart');

      case MontyCrashError():
        // The isolate or WASM Worker died. Restart immediately.
        print('crash: process died — restart immediately');

      case MontyDisposedError():
        // Bug in calling code — do NOT restart.
        print('disposed: caller bug — fix the code');

      case MontyResourceError():
        print('resource: OOM/timeout — reduce load, then restart');
    }
  }

  handleError(MontySyntaxError('bad syntax', excType: 'SyntaxError'));
  handleError(MontyScriptError('value error', excType: 'ValueError'));
  handleError(MontyPanicError('rust panic'));
  handleError(MontyCrashError('worker died'));
  handleError(MontyDisposedError('use after dispose'));
  handleError(MontyResourceError('OOM'));
}

void _printException(MontyException? e) {
  if (e == null) return;
  print('  exception:');
  print('    filename: ${e.filename}');
  print('    line:     ${e.lineNumber}');
  print('    source:   ${e.sourceCode}');
  print('    traceback (${e.traceback.length} frames):');
  for (final frame in e.traceback) {
    print('      ${frame.filename}:${frame.startLine}  ${frame.frameName}');
    if (frame.previewLine != null) print('        ${frame.previewLine}');
  }
}

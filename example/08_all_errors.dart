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
  await _errorInResult(); // Python errors land in result.error, not thrown
  await _syntaxError();
  await _scriptError();
  await _resourceError();
  await _disposedError();
  _exhaustivePatternMatch();
}

// ── Python errors in result.error ────────────────────────────────────────────
// A Python exception does NOT throw in Dart.
// It appears in MontyResult.error while result.value is MontyNone.
Future<void> _errorInResult() async {
  print('\n── error in result (no throw) ──');
  final r = await Monty.exec('1 / 0');
  print('isError: ${r.isError}');
  final e = r.error;
  if (e != null) {
    print('excType:  ${e.excType}'); // ZeroDivisionError
    print('message:  ${e.message}');
    print('line:     ${e.lineNumber}');
    print('value:    ${r.value}'); // MontyNone
  }
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
// MontyScriptError is the exception type for Python-level errors. Both
// Monty.exec and MontyRepl.feedRun return errors as data via
// MontyResult.error rather than throwing — the REPL stays alive and can
// keep running. MontyScriptError appears in MontyResult.error.exception
// for callers who want to inspect typed details (excType, traceback,
// line number).
Future<void> _scriptError() async {
  print('\n── MontyScriptError (in result.error, REPL survives) ──');

  final repl = MontyRepl();
  final r = await repl.feedRun('''
def outer():
    inner()

def inner():
    raise ValueError("deep error")

outer()
''');

  final e = r.error;
  if (e != null) {
    print('script error!');
    print('  excType:  ${e.excType}');
    print('  message:  ${e.message}');
    _printException(e);
  }

  // The REPL is still alive — keep running.
  final r2 = await repl.feedRun('1 + 1');
  print('next call works: ${r2.value}');
  repl.dispose();
}

// ── MontyResourceError ────────────────────────────────────────────────────────
// Thrown on OOM, execution timeout, WASM trap, or stack overflow.
Future<void> _resourceError() async {
  print('\n── MontyResourceError (timeout) ──');
  try {
    await Monty.exec(
      'while True: pass', // infinite loop
      limits: const MontyLimits(timeoutMs: 200),
    );
  } on MontyResourceError catch (e) {
    print('resource error: ${e.message}');
  }
}

// ── MontyDisposedError ────────────────────────────────────────────────────────
// Thrown when you use an interpreter after calling dispose().
Future<void> _disposedError() async {
  print('\n── MontyDisposedError ──');
  final repl = MontyRepl()..dispose();
  try {
    await repl.feedRun('1 + 1');
    print('should not reach here');
  } on MontyDisposedError catch (e) {
    print('disposed error: ${e.message}');
  } on StateError catch (e) {
    // MontyRepl reports use-after-dispose as a StateError today, not as
    // MontyDisposedError; the earlier `.catchError` hid that by ignoring it.
    print('disposed (StateError): ${e.message}');
  }
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

      case MontySuspensionBudgetExceeded(:final budget):
        // The host's suspension bound was hit; the sandbox cannot catch it.
        print('suspensions: more than $budget host calls — raise the bound');
    }
  }

  handleError(const MontySyntaxError('bad syntax', excType: 'SyntaxError'));
  handleError(const MontyScriptError('value error', excType: 'ValueError'));
  handleError(const MontyPanicError('rust panic'));
  handleError(const MontyCrashError('worker died'));
  handleError(const MontyDisposedError('use after dispose'));
  handleError(const MontyResourceError('OOM'));
  handleError(const MontySuspensionBudgetExceeded(100));
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

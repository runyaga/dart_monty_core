// 04 — MontyRepl: mid-level iterative execution
//
// MontyRepl gives you manual control over the start/resume loop.
// You drive MontyProgress yourself instead of letting Monty.run auto-dispatch.
// Useful when you need fine-grained timing, interleaving, or custom dispatch.
//
// Covers: MontyRepl, start, resume, resumeWithError, resumeWithException,
//         MontyProgress (MontyComplete, MontyPending, MontyOsCall),
//         MontyPending.kwargs, MontyPending.methodCall, MontyPending.callId.
//
// Run: dart run example/04_session.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _autoDispatch();
  await _manualLoop();
  await _resumeWithError();
  await _osCallManual();
}

// ── Auto-dispatch (same as Monty.run) ────────────────────────────────────────
// MontyRepl.run() drives the loop automatically just like Monty.run.
Future<void> _autoDispatch() async {
  print('\n── auto-dispatch ──');
  final repl = MontyRepl();

  await repl.feedRun(
    'greeting = greet("Dart")',
    externalFunctions: {'greet': (args) async => 'Hi, ${args["_0"]}!'},
  );
  print('auto: ${(await repl.feedRun("greeting")).value}');
  repl.dispose();
}

// ── Manual loop ───────────────────────────────────────────────────────────────
// repl.feedStart() returns the first MontyProgress.
// Loop with resume() until MontyComplete.
Future<void> _manualLoop() async {
  print('\n── manual loop ──');
  final repl = MontyRepl();

  // Register which external names Python can call.
  var progress = await repl.feedStart(
    '''
a = compute(5)
b = compute(a)
result = a + b
''',
    externalFunctions: ['compute'],
  );

  var callCount = 0;
  while (true) {
    switch (progress) {
      case MontyComplete(:final result):
        print('result: ${result.value}');
        print('calls dispatched: $callCount');
        repl.dispose();
        return;

      case MontyPending(
        :final functionName,
        :final arguments,
        kwargs: _,
        :final callId,
        :final methodCall,
      ):
        callCount++;
        print(
          '  call #$callId: $functionName(${arguments.map((a) => a.dartValue)})  method=$methodCall',
        );
        final n = arguments.first.dartValue as int;
        // Resume with the computed value. It must be JSON-encodable.
        progress = await repl.resume(n * 2);

      case MontyOsCall():
        // Not expected here — resume with error.
        progress = await repl.resumeWithError('os calls not supported');

      case MontyNameLookup(:final variableName):
        // Name resolution — signal undefined.
        progress = await repl.resumeWithError('$variableName not found');

      case MontyResolveFutures():
        progress = await repl.resume(null);
    }
  }
}

// ── resumeWithError ────────────────────────────────────────────────────────────
// Raises a RuntimeError in Python from the pending external call site.
// Python can catch it with try/except — it's a normal Python exception.
Future<void> _resumeWithError() async {
  print('\n── resumeWithError ──');
  final repl = MontyRepl();

  var progress = await repl.feedStart(
    '''
try:
    x = risky_call()
    result = f"got {x}"
except RuntimeError as e:
    result = f"error: {e}"
''',
    externalFunctions: ['risky_call'],
  );

  while (true) {
    switch (progress) {
      case MontyComplete():
        print(await repl.feedRun('result'));
        repl.dispose();
        return;
      case MontyPending():
        // Inject an error into Python at the call site.
        progress = await repl.resumeWithError('something went wrong');
      default:
        progress = await repl.resume(null);
    }
  }
}

// ── OS call manual dispatch ───────────────────────────────────────────────────
// MontyOsCall fires for pathlib/os/datetime. You can handle it yourself
// instead of providing an osHandler at construction time.
Future<void> _osCallManual() async {
  print('\n── os call manual ──');
  final repl = MontyRepl();

  var progress = await repl.feedStart('''
import pathlib
content = pathlib.Path("/data/notes.txt").read_text()
''');

  while (true) {
    switch (progress) {
      case MontyComplete():
        print('content: ${(await repl.feedRun("content")).value}');
        repl.dispose();
        return;

      case MontyOsCall(:final operationName, arguments: _):
        // Intercept and handle the OS call manually.
        Object? value;
        if (operationName == 'Path.read_text') {
          value = 'manual dispatch: hello!';
        }
        progress = await repl.resume(value);

      case MontyPending():
        progress = await repl.resume(null);

      default:
        progress = await repl.resume(null);
    }
  }
}

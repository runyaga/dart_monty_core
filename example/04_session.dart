// 04 — MontySession: mid-level iterative execution
//
// MontySession gives you manual control over the start/resume loop.
// You drive MontyProgress yourself instead of letting Monty.run auto-dispatch.
// Useful when you need fine-grained timing, interleaving, or custom dispatch.
//
// Covers: MontySession, start, resume, resumeWithError, resumeWithException,
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
// MontySession.run() drives the loop automatically just like Monty.run.
Future<void> _autoDispatch() async {
  print('\n── auto-dispatch ──');
  final session = MontySession();

  await session.run(
    'greeting = greet("Dart")',
    externals: {'greet': (args) async => 'Hi, ${args["_0"]}!'},
  );
  print('auto: ${(await session.run("greeting")).value}');
  session.dispose();
}

// ── Manual loop ───────────────────────────────────────────────────────────────
// session.start() returns the first MontyProgress.
// Loop with resume() until MontyComplete.
Future<void> _manualLoop() async {
  print('\n── manual loop ──');
  final session = MontySession();

  // Register which external names Python can call.
  var progress = await session.start(
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
        session.dispose();
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
        progress = await session.resume(n * 2);

      case MontyOsCall():
        // Not expected here — resume with error.
        progress = await session.resumeWithError('os calls not supported');

      case MontyNameLookup(:final variableName):
        // Name resolution — signal undefined.
        progress = await session.resumeWithError('$variableName not found');

      case MontyResolveFutures():
        progress = await session.resume(null);
    }
  }
}

// ── resumeWithError ────────────────────────────────────────────────────────────
// Raises a RuntimeError in Python from the pending external call site.
// Python can catch it with try/except — it's a normal Python exception.
Future<void> _resumeWithError() async {
  print('\n── resumeWithError ──');
  final session = MontySession();

  var progress = await session.start(
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
        print(await session.run('result'));
        session.dispose();
        return;
      case MontyPending():
        // Inject an error into Python at the call site.
        progress = await session.resumeWithError('something went wrong');
      default:
        progress = await session.resume(null);
    }
  }
}

// ── OS call manual dispatch ───────────────────────────────────────────────────
// MontyOsCall fires for pathlib/os/datetime. You can handle it yourself
// instead of providing an osHandler at construction time.
Future<void> _osCallManual() async {
  print('\n── os call manual ──');
  final session = MontySession();

  var progress = await session.start('''
import pathlib
content = pathlib.Path("/data/notes.txt").read_text()
''');

  while (true) {
    switch (progress) {
      case MontyComplete():
        print('content: ${(await session.run("content")).value}');
        session.dispose();
        return;

      case MontyOsCall(:final operationName, arguments: _):
        // Intercept and handle the OS call manually.
        Object? value;
        if (operationName == 'Path.read_text') {
          value = 'manual dispatch: hello!';
        }
        progress = await session.resume(value);

      case MontyPending():
        progress = await session.resume(null);

      default:
        progress = await session.resume(null);
    }
  }
}

// 06 — Compile, precompiled execution, and platform-level APIs
//
// This file exercises the lower-level platform abstractions:
//
//  Monty.compile()       → bytecode blob
//  Monty.runPrecompiled() → run blob without a session
//  createPlatformMonty() → direct MontyPlatform access
//  MontySnapshotCapable  → platform-level snapshot/restore
//  MontyFutureCapable    → async future resolution protocol
//  MontyNameLookup       → dynamic name resolution
//  ReplPlatform          → use MontyRepl as a MontyPlatform
//
// Run: dart run example/06_compile_and_platform.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _compileAndRun();
  await _platformDirect();
  await _snapshotCapable();
  await _futureCapable();
  await _nameLookup();
  await _replPlatform();
}

// ── Compile + runPrecompiled ──────────────────────────────────────────────────
// Compile once, run many times — avoids re-parsing on repeated execution.
Future<void> _compileAndRun() async {
  print('\n── compile + runPrecompiled ──');

  const src = '''
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a

fib(10)
''';

  // Compile to bytecode.
  final bytecode = await Monty.compile(src);
  print('bytecode: ${bytecode.length} bytes');

  // Run precompiled — stateless, disposable interpreter per call.
  final r1 = await Monty.runPrecompiled(bytecode);
  print('fib(10) = ${r1.value}'); // 55

  // Same bytecode, run again.
  final r2 = await Monty.runPrecompiled(bytecode);
  print('fib(10) = ${r2.value}'); // 55 — independent run
}

// ── createPlatformMonty(): direct platform access ────────────────────────────
// Returns MontyFfi on native, MontyWasm on web — same MontyPlatform interface.
Future<void> _platformDirect() async {
  print('\n── platform direct ──');

  final platform = createPlatformMonty();
  try {
    // Same API as MontySession.run but without session state management.
    final r = await platform.run('"hello from platform".upper()');
    print('upper: ${r.value}');

    // Compile + runPrecompiled at the platform level.
    final bytecode = await platform.compileCode('sum(range(100))');
    final r2 = await platform.runPrecompiled(bytecode);
    print('sum(range(100)) = ${r2.value}'); // 4950
  } finally {
    await platform.dispose();
  }
}

// ── Platform-level snapshot via Monty/MontySession ───────────────────────────
// MontySnapshotCapable is an internal interface on MontyFfi/MontyWasm.
// Public snapshot/restore is exposed via Monty, MontySession, and MontyRepl.
// Use those — they handle the platform details for you.
Future<void> _snapshotCapable() async {
  print('\n── snapshot at each API level ──');

  // High-level: Monty.snapshot() / Monty.restore()
  final monty = Monty();
  await monty.run('x = 42; items = [1, 2, 3]');
  final snap1 = await monty.snapshot();
  print('Monty snapshot: ${snap1.length} bytes');
  await monty.run('x = 99');
  await monty.restore(snap1);
  print('Monty restore → x = ${(await monty.run("x")).value}'); // 42
  monty.dispose();

  // Mid-level: MontySession.snapshot() / MontySession.restore()
  final session = MontySession();
  await session.run('count = 10');
  final snap2 = await session.snapshot();
  print('MontySession snapshot: ${snap2.length} bytes');
  await session.run('count = 999');
  await session.restore(snap2);
  print('MontySession restore → count = ${(await session.run("count")).value}'); // 10
  session.dispose();

  // Low-level: MontyRepl.snapshot() / MontyRepl.restore()
  final repl = MontyRepl();
  await repl.feed('n = 7');
  final snap3 = await repl.snapshot();
  print('MontyRepl snapshot: ${snap3.length} bytes');
  await repl.feed('n = 0');
  await repl.restore(snap3);
  print('MontyRepl restore → n = ${(await repl.feed("n")).value}'); // 7
  await repl.dispose();
}

// ── MontyFutureCapable ────────────────────────────────────────────────────────
// The async-future protocol lets multiple external calls run concurrently
// within a single Python execution (via asyncio.gather).
//
// Protocol:
//  1. Python hits `await ext_fn()` → MontyPending
//  2. Call resumeAsFuture() → continues to next await, returns MontyPending or MontyResolveFutures
//  3. When all awaits seen → MontyResolveFutures with pendingCallIds
//  4. Call resolveFutures({id: result, ...}) → continues execution
Future<void> _futureCapable() async {
  print('\n── MontyFutureCapable ──');

  final platform = createPlatformMonty();
  try {
    if (platform is! MontyFutureCapable) {
      print('platform does not support futures');
      return;
    }

    var progress = await platform.start(
      '''
import asyncio
async def fetch(name):
    return name

async def main():
    a, b = await asyncio.gather(fetch("alice"), fetch("bob"))
    return [a, b]

asyncio.run(main())
''',
    );

    // Drive the futures protocol.
    final pendingCalls = <int, MontyPending>{}; // callId → pending

    while (true) {
      switch (progress) {
        case MontyComplete(:final result):
          print('gathered: ${result.value}');
          return;

        case MontyPending(:final callId):
          pendingCalls[callId] = progress;
          // Signal: this call will be resolved as a future.
          progress = await platform.resumeAsFuture();

        case MontyResolveFutures(:final pendingCallIds):
          // All futures are awaiting resolution — resolve them all at once.
          final results = <int, Object?>{};
          for (final id in pendingCallIds) {
            final call = pendingCalls[id]!;
            results[id] = call.arguments.first.dartValue; // echo the name arg
          }
          progress = await platform.resolveFutures(results);

        default:
          progress = await platform.resume(null);
      }
    }
  } finally {
    await platform.dispose();
  }
}

// ── MontyNameLookup ───────────────────────────────────────────────────────────
// Python raises NameError for undefined names by default. With NameLookup,
// the VM pauses and asks Dart to resolve the name dynamically.
//
// Use resumeNameLookup(name, value) to provide a value,
// or resumeNameLookupUndefined(name) to signal NameError.
Future<void> _nameLookup() async {
  print('\n── MontyNameLookup ──');

  final platform = createPlatformMonty();
  try {
    // NameLookup fires when Python accesses a name not in scope.
    // Here SECRET_KEY is not defined in Python — the VM asks Dart.
    var progress = await platform.start('SECRET_KEY + "_suffix"');
    final db = <String, Object?>{'SECRET_KEY': 'dart-injected-value'};

    while (true) {
      switch (progress) {
        case MontyComplete(:final result):
          print('resolved: ${result.value}');
          return;
        case MontyNameLookup(:final variableName):
          if (db.containsKey(variableName)) {
            progress = await platform.resumeNameLookup(
              variableName,
              db[variableName],
            );
          } else {
            // Signal NameError — Python raises NameError.
            progress = await platform.resumeNameLookupUndefined(variableName);
          }
        default:
          progress = await platform.resume(null);
      }
    }
  } finally {
    await platform.dispose();
  }
}

// ── ReplPlatform ──────────────────────────────────────────────────────────────
// Adapter: wraps a MontyRepl to implement MontyPlatform.
// Lets you pass a MontyRepl wherever MontyPlatform is expected.
Future<void> _replPlatform() async {
  print('\n── ReplPlatform ──');

  final repl = MontyRepl();
  final platform = ReplPlatform(repl: repl);

  // ReplPlatform exposes the same MontyPlatform API.
  await platform.run('x = 100');
  final r = await platform.run('x + 1');
  print('x + 1 = ${r.value}'); // 101

  // The underlying repl retains state.
  await repl.feed('x += 50');
  print('x after repl feed: ${(await platform.run("x")).value}'); // 151

  await platform.dispose(); // disposes the underlying repl too
}

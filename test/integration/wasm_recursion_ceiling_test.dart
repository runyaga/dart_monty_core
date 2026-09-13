@Tags(['wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
// BaseMontyPlatform is internal: the default lives with the code that
// substitutes it, so there is ONE source of truth rather than a copy here.
import 'package:dart_monty_core/src/platform/base_monty_platform.dart';
import 'package:test/test.dart';

/// The WASM half of the recursion-ceiling guard. Its FFI twin is
/// `test/integration/ffi_recursion_ceiling_test.dart`; the two exist so that
/// [BaseMontyPlatform.defaultStackDepth] is proven survivable on EVERY
/// backend, not just the one that happened to be measured.
///
/// WHY BOTH HALVES ARE REQUIRED. The corpus is a CONFORMANCE suite: the same
/// fixtures run on native FFI, dart2js and dart2wasm, and the whole point is
/// that they agree. A recursion limit that holds on one backend and not another
/// would make a fixture raise RecursionError on one and succeed on another —
/// a divergence produced by our configuration rather than by the engine.
///
/// THE FAILURE MODES DIFFER, WHICH IS WHY THIS IS NOT A COPY OF THE FFI TEST.
/// The native stack and the wasm32 stack are different things:
///
///     FFI   overruns the real thread stack -> SIGSEGV, THE HOST PROCESS DIES.
///           Nothing is catchable; the suite dies with a partial result, so
///           that test must probe in a child process.
///     WASM  overruns a stack living in LINEAR MEMORY -> the module traps.
///           The trap surfaces as MontyPanicError and is CONTAINED, so it can
///           be asserted in-process — but it is still a failure. A trap means
///           the limit was too deep for this backend to reach its own guard.
///
/// So this test asserts the POSITIVE outcome — a RecursionError — and treats a
/// trap as the failure it is, rather than asserting "did not crash", which a
/// trap would satisfy.
///
/// MEASURED, all three backends, monty v0.0.23 (linux/arm64 for FFI):
///
///     depth   FFI              dart2js        dart2wasm
///     2000    -                WASM trap      WASM trap
///     1000    SIGSEGV (-11)    WASM trap      WASM trap
///      512    RecursionError   RecursionError RecursionError
///      256    RecursionError   RecursionError RecursionError
///
/// 512 is the value all three agree on. 1000 — CPython's default, and what
/// monty uses when no limit is given — fails on all three.
void main() {
  // The same shapes as the FFI test, so a divergence between backends is
  // visible as one failing where the other passes.
  const shapes = <String, String>{
    // Worst case on native. If a backend regresses, expect this one first.
    'cyclic dict': '''
a = {}
b = {}
a["x"] = b
b["x"] = a
a == b
''',
    'cyclic deque': '''
from collections import deque
a = deque()
b = deque()
a.append(b)
b.append(a)
a == b
''',
    'cyclic list': '''
a = []
b = []
a.append(b)
b.append(a)
a == b
''',
    // Two SEPARATE but structurally identical cyclic graphs. Comparing a cycle
    // against a fresh literal terminates on the first difference and never
    // recurses — an earlier version of the FFI test did exactly that and
    // passed while proving nothing.
    'mixed cycle': '''
a = {}
b = {}
a["x"] = [a]
b["x"] = [b]
a == b
''',
  };

  group('defaultStackDepth is survivable on this WASM backend', () {
    for (final MapEntry(key: name, value: src) in shapes.entries) {
      test(
        '$name raises RecursionError, does not trap',
        () async {
          final platform = createPlatformMonty();
          String outcome;
          String? excType;
          try {
            final result = await platform.run(
              src,
              limits: const MontyLimits(
                memoryBytes: 256 * 1024 * 1024,
                stackDepth: BaseMontyPlatform.defaultStackDepth,
              ),
              scriptName: 'ceiling_$name.py',
            );
            // An error RETURNED rather than thrown is a normal shape here.
            excType = result.error?.excType;
            outcome = '${result.error}';
          } on MontyScriptError catch (e) {
            excType = e.excType;
            outcome = '$e';
          } on Object catch (e) {
            outcome = '$e';
          } finally {
            await platform.dispose();
          }

          // A trap means the limit was deeper than this backend could reach its
          // own guard from. Name it explicitly — "not a crash" is not the bar.
          expect(
            outcome,
            isNot(contains('WASM trap')),
            reason:
                'WASM TRAP: BaseMontyPlatform.defaultStackDepth '
                '(${BaseMontyPlatform.defaultStackDepth}) is deeper than this '
                'backend '
                'can sustain for "$name". The wasm32 stack (which lives in '
                'linear memory) overflowed before monty could raise '
                'RecursionError. LOWER defaultStackDepth — and keep it in step '
                'with the FFI half, or the backends diverge. Got: $outcome',
          );
          // And the guard must actually have fired. Completing normally would
          // mean the script never recursed, so it proves nothing about the
          // ceiling.
          // Assert on excType, NOT on toString(). MontyScriptError is THROWN
          // when the interpreter hits a Python-level exception and CARRIES the
          // structured MontyException, whose `excType` names the Python
          // exception. Their toString()s differ by backend — FFI renders
          // "MontyException: RecursionError: ..." while WASM renders
          // "MontyScriptError: maximum recursion depth exceeded" — so matching
          // on text would fail a backend that behaved CORRECTLY. excType is
          // the same on both; fixture_runner.dart reads it the same way.
          expect(
            excType,
            'RecursionError',
            reason:
                'PROVED NOTHING: "$name" did not surface excType '
                '"RecursionError", so it never stressed the recursion guard '
                'and says nothing about whether '
                '${BaseMontyPlatform.defaultStackDepth} is survivable here. '
                'Got excType=$excType rendered=$outcome',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}

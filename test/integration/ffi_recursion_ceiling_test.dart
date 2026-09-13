@Tags(['ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
// BaseMontyPlatform is internal: the default lives with the code that
// substitutes it, so there is ONE source of truth rather than a copy here.
import 'package:dart_monty_core/src/platform/base_monty_platform.dart';
import 'package:test/test.dart';

/// The FFI half of the recursion-ceiling guard. Its twin is
/// `test/integration/wasm_recursion_ceiling_test.dart`; both exist so
/// [BaseMontyPlatform.defaultStackDepth] is proven survivable on EVERY backend.
///
/// WHY BOTH HALVES. The corpus is a CONFORMANCE suite — the same fixtures run
/// on native FFI, dart2js and dart2wasm, and the point is that they agree. A
/// recursion limit safe on one backend and not another would make a fixture
/// raise RecursionError on one and succeed on another: a divergence produced
/// by our configuration rather than by the engine.
///
/// WHY THIS ASSERTS IN-PROCESS, WITH NO CHILD PROBE. An earlier version ran
/// each case as a `dart run` CHILD so a crash could be observed rather than
/// taken. That pattern is unusable here, twice proven on GitHub's linux_x64
/// runners and never reproducible on arm64:
///
///     ===== CRASH =====
///     si_signo=Segmentation fault(11), si_code=SEGV_MAPERR(1), si_addr=0x103c
///     -> Aborted (exit 134)
///
/// Spawning a `dart run` child from inside this suite kills the PARENT in the
/// dynamic loader. The same signature took out the whole FFI job when the
/// quarantine's crash-probe guards did it (removed in 181351a), and it
/// returned the moment this test reintroduced the pattern. So: no children.
///
/// What that costs, stated plainly: if the default stack depth ever
/// becomes too deep for a platform, this test cannot report it cleanly — the
/// stack overflow takes the whole suite down with a bare exit 139. That is
/// still a loud failure, just an ugly one, and it is the same way the corpus
/// itself would fail. The WASM half CAN report cleanly, because a wasm32
/// stack overflow is a contained trap rather than a process death.
///
/// MEASURED, monty v0.0.23, by bisecting each shape's crash point on
/// linux/arm64 (`safe / SIGSEGV`):
///
///     cyclic dict == dict     534 / 539   <-- worst case, sets the bound
///     cyclic deque == deque   765 / 781
///     cyclic list, deep repr, deep hash, heavy Python frames   >= 765
///
/// Not an upstream bug: `pydantic-monty 0.0.23` — the tag native/Cargo.toml
/// pins — raises RecursionError on these same scripts and its parent survives,
/// because upstream runs the engine in SUBPROCESS WORKERS with a full
/// main-thread stack. An FFI call runs on a Dart isolate thread with far less,
/// and `ulimit -s` cannot change that: 8MB, 64MB and unlimited all segfault
/// identically, because the isolate thread's stack is fixed at creation.
void main() {
  const shapes = {
    // Worst case measured. If a platform regresses, expect this one first.
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
    // recurses — an earlier version did exactly that and passed while proving
    // nothing.
    'mixed cycle': '''
a = {}
b = {}
a["x"] = [a]
b["x"] = [b]
a == b
''',
  };

  group('defaultStackDepth is survivable on this platform', () {
    for (final MapEntry(key: name, value: src) in shapes.entries) {
      test(
        '$name raises RecursionError at defaultStackDepth',
        () async {
          final repl = MontyRepl(
            limits: const MontyLimits(
              memoryBytes: 256 * 1024 * 1024,
              stackDepth: BaseMontyPlatform.defaultStackDepth,
            ),
          );
          String? excType;
          String rendered;
          try {
            final r = await repl.feedRun(src);
            // An error RETURNED rather than thrown is the normal shape here.
            excType = r.error?.excType;
            rendered = '${r.error}';
          } on MontyScriptError catch (e) {
            excType = e.excType;
            rendered = '$e';
          } on Object catch (e) {
            rendered = '$e';
          } finally {
            await repl.dispose();
          }

          // Assert on excType, NOT toString(). MontyScriptError is THROWN when
          // the interpreter hits a Python-level exception and CARRIES the
          // structured MontyException, whose `excType` names it. The renderings
          // differ by backend — FFI "MontyException: RecursionError: ...",
          // WASM "MontyScriptError: maximum recursion depth exceeded" — so text
          // matching would fail a backend that behaved CORRECTLY.
          expect(
            excType,
            'RecursionError',
            reason:
                'PROVED NOTHING: "$name" did not surface excType '
                '"RecursionError", so it never stressed the recursion '
                'guard and '
                'says nothing about whether '
                '${BaseMontyPlatform.defaultStackDepth} is survivable here. '
                'Got excType=$excType rendered=$rendered',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}

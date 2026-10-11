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
/// WHERE THE STACK COMES FROM. Every interpreter call runs on a dedicated
/// thread with a fixed 16 MiB stack (`interpreter_stack` in
/// native/src/error.rs), mirroring upstream's own worker thread. Before that it
/// ran on whatever Dart thread made the FFI call: ~1 MiB on macOS, fixed at
/// thread creation, so `ulimit -s` never helped.
///
/// MEASURED, monty v0.0.23, macOS arm64, cyclic dict (the worst shape),
/// `safe / killed` by bisection:
///
///     Dart thread stack, rustc 1.98.0     549 / 550
///     Dart thread stack, rustc 1.99.0     509 / 510   <-- default 512 died
///     16 MiB interpreter stack, 1.99.0   8191 / 8192
///
/// The Dart SDK was NOT a factor: 3.11.4 and 3.13.5 give the FFI call the same
/// 1036 KiB stack, and the 2x2 (Dart 3.11.4 / 3.13.5 x rustc 1.98 / 1.99)
/// crashes exactly on the rustc 1.99 column. A compiler upgrade moved the
/// ceiling 7%, under a default that had a 7% margin. Hence the second group:
/// [_headroomFactor] times the default must also be survivable, so the next
/// codegen change has to eat most of a 16x margin before it reaches users.
///
/// Not an upstream bug: `pydantic-monty 0.0.23` — the tag native/Cargo.toml
/// pins — raises RecursionError on these same scripts and its parent survives.
const _headroomFactor = 4;

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

  const depths = {
    'defaultStackDepth is survivable on this platform':
        BaseMontyPlatform.defaultStackDepth,
    'the interpreter stack has ${_headroomFactor}x headroom over the default':
        BaseMontyPlatform.defaultStackDepth * _headroomFactor,
  };

  for (final MapEntry(key: groupName, value: depth) in depths.entries) {
    group(groupName, () {
      for (final MapEntry(key: name, value: src) in shapes.entries) {
        test(
          '$name raises RecursionError at stackDepth $depth',
          () async {
            final repl = MontyRepl(
              limits: MontyLimits(
                memoryBytes: 256 * 1024 * 1024,
                stackDepth: depth,
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

            // Assert on excType, NOT toString(). MontyScriptError is THROWN
            // when the interpreter hits a Python-level exception and CARRIES
            // the structured MontyException, whose `excType` names it. The
            // renderings differ by backend — FFI "MontyException:
            // RecursionError: ...", WASM "MontyScriptError: maximum recursion
            // depth exceeded" — so text matching would fail a backend that
            // behaved CORRECTLY.
            expect(
              excType,
              'RecursionError',
              reason:
                  'PROVED NOTHING: "$name" did not surface excType '
                  '"RecursionError", so it never stressed the recursion '
                  'guard and '
                  'says nothing about whether '
                  '$depth is survivable here. '
                  'Got excType=$excType rendered=$rendered',
            );
          },
          timeout: const Timeout(Duration(minutes: 2)),
        );
      }
    });
  }
}

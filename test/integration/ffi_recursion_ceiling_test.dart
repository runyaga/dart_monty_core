@Tags(['ffi'])
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Guards [MontyLimits.defaultStackDepth] against the ONE failure it exists to
/// prevent: a recursion limit set deeper than the native stack can sustain, so
/// the stack overflows before monty's counter trips and the HOST PROCESS
/// SEGFAULTS. There is no exception to catch when that happens — the process
/// is gone, and every suite sharing it dies with a partial result.
///
/// Monty itself is not at fault and this is not an upstream bug: the same
/// engine raises RecursionError correctly at any depth it can actually reach.
/// Verified against `pydantic-monty 0.0.23` (the tag native/Cargo.toml pins),
/// which survives these same scripts because upstream runs the engine in
/// SUBPROCESS WORKERS with a full main-thread stack, while an FFI call runs on
/// a Dart isolate's thread with far less.
///
/// Each case runs in a CHILD PROCESS. A crash cannot be asserted in-process —
/// it would take this suite with it — so the child's exit code is the verdict:
///
///     exit 0   -> monty raised RecursionError, the guard won      (PASS)
///     exit 139 -> SIGSEGV, the limit is deeper than this platform
///                 can sustain and the default is UNSAFE HERE      (FAIL)
///
/// Cost per frame is NOT uniform. A cyclic dict comparison burns far more
/// native stack per level than a Python call frame, so the bound is the
/// minimum across shapes. Measured on linux/arm64, monty v0.0.23:
///
///     cyclic dict == dict     safe 534 / SIGSEGV 539   <-- worst case
///     cyclic deque == deque   safe 765 / SIGSEGV 781
///
/// CI runs amd64, where frame sizes differ. This test re-measures on whatever
/// platform it runs on rather than trusting those numbers.
void main() {
  const shapes = <String, String>{
    // The worst shape measured. If any case fails, expect this one first.
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
    // Two SEPARATE but structurally identical cyclic graphs. Comparing a
    // cycle against a fresh literal terminates early on the first difference
    // and never recurses — an earlier version of this case did exactly that
    // and passed while proving nothing.
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
        '$name at defaultStackDepth raises, does not crash',
        () async {
          // The child MUST live inside the package. Written to systemTemp it
          // cannot resolve `package:dart_monty_core`, exits 254 on a compile
          // error, and never runs the code under test — which made an earlier
          // version of this test pass at a depth that segfaults.
          final dir = Directory(
            '${Directory.current.path}/.dart_tool/recursion_ceiling',
          )..createSync(recursive: true);
          try {
            // The Python is written to a FILE, never embedded in the child's
            // source. Embedding meant escaping ($, quotes, newlines) could
            // silently alter the script, so the child ran DIFFERENT code than
            // intended — it reported "proved nothing" for a case that segfaults
            // when the same Python is run by hand.
            final pyFile = File('${dir.path}/case.py')..writeAsStringSync(src);
            final script = File('${dir.path}/case.dart')
              ..writeAsStringSync('''
import 'dart:io';
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final repl = MontyRepl(
    limits: const MontyLimits(
      memoryBytes: 256 * 1024 * 1024,
      stackDepth: MontyLimits.defaultStackDepth,
    ),
  );
  var verdict = 3; // 3 = ran but proved nothing
  try {
    final r = await repl.feedRun(File(r'${pyFile.path}').readAsStringSync());
    // An error RETURNED (not thrown) is the normal shape here.
    final err = '\${(r as dynamic).error}';
    verdict = err.contains('RecursionError') ? 0 : 3;
  } on Object catch (e) {
    // A THROWN RecursionError is equally correct; anything else is not.
    verdict = '\$e'.contains('RecursionError') ? 0 : 3;
  } finally {
    repl.dispose();
  }
  // 0 ONLY when monty's guard demonstrably fired. Exiting 0 merely because
  // nothing crashed would make this test pass while proving nothing — the
  // failure mode that made an earlier version of it worthless.
  exit(verdict);
}
''');
            final r = await Process.run('dart', ['run', script.path]);
            // Assert the child RAN, not merely that it avoided one exit code.
            // `isNot(139)` alone is satisfied by a child that failed to compile
            // (exit 254) and therefore proved nothing.
            expect(
              r.exitCode,
              isNot(254),
              reason:
                  'the probe child failed to COMPILE, so this case proved '
                  'nothing. It must sit inside the package to resolve '
                  'package:dart_monty_core. stderr:\n${r.stderr}',
            );
            expect(
              r.exitCode,
              // 0 ONLY if the child saw a RecursionError; 3 = proved nothing.
              0,
              // Process.run reports a signal death as -signal (SIGSEGV = -11).
              // Only a SHELL reports 128+signal (139). This repo has been
              // caught
              // by that before — knownReplCrashFixtures records exitCode: -11.
              reason: (r.exitCode == -11 || r.exitCode == 139)
                  ? 'SIGSEGV: MontyLimits.defaultStackDepth '
                        '(${MontyLimits.defaultStackDepth}) is deeper than '
                        'this '
                        "platform's FFI thread stack can sustain for "
                        '"$name". '
                        'The native stack overflowed before monty could raise '
                        'RecursionError, killing the process. LOWER '
                        'defaultStackDepth — do not quarantine the fixture '
                        'that '
                        'exposed it. stderr:\n${r.stderr}'
                  : 'PROVED NOTHING: "$name" ran to completion without a '
                        'RecursionError, so it never stressed the recursion '
                        'guard and says nothing about whether '
                        '${MontyLimits.defaultStackDepth} is survivable. Fix '
                        'the '
                        'script so it actually recurses — comparing a cycle '
                        'against a fresh literal terminates early. '
                        'stdout:\n${r.stdout}',
            );
          } finally {
            dir.deleteSync(recursive: true);
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}

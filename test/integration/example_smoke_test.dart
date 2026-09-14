// Smoke test: every example/*.dart compiles and exits 0.
//
// `dart analyze` and `dart pub publish` only check that examples type-check;
// neither runs them. This test fills the runtime-rot gap. Each example file
// is invoked via `dart run` from the repo root and asserted to exit 0 within
// a generous timeout. stdout / stderr surface in the failure reason so a
// regression is debuggable from the test report.
//
// Tagged 'example' (skipped in default `dart test` runs because each example
// boots an FFI dylib + interpreter — slow for fast-loop unit testing).
//
// Run: dart test -p vm --run-skipped --tags=example

@Tags(['integration', 'example'])
library;

import 'dart:io';

import 'package:test/test.dart';

/// Examples that currently fail or hang on `main`. Each entry is a
/// regression to fix; once fixed, remove the entry so the test enforces
/// the example.
const _skipReasons = {
  // REASON CORRECTED 2026-09-14. It previously blamed resumeNameLookupValue
  // being unsupported on FFI. That was fixed (06da3ba) and the file now holds
  // zero UnimplementedError, so the stale reason was hiding the real cause
  // TWICE over: the example also failed to COMPILE on a duplicate `repl`
  // declaration, which masked the runtime fault behind it.
  //
  // The compile error is fixed. What remains is a LIBRARY defect, not an
  // example defect: Monty.compile() is broken on the FFI backend.
  //   FfiCoreBindings.compileCode (ffi_core_bindings.dart:186-191) calls
  //   _bindings.snapshot() on a handle from _bindings.create(), i.e. a
  //   ONE-SHOT handle, and native_bindings_ffi.dart:297 refuses exactly that:
  //     "snapshot is not supported on the one-shot handle: monty's SessionRef
  //      has no variant for an un-started MontyRun ... Use MontyRepl."
  // So every Monty.compile() call throws Bad state on FFI. Not tracked by any
  // of the 47 open issues as of 2026-09-14. Now filed as core#152.
  'example/06_compile_and_platform.dart':
      'BLOCKED on a library defect: Monty.compile() throws "snapshot is not '
      'supported on the one-shot handle" — compileCode snapshots a one-shot '
      'handle (ffi_core_bindings.dart:186-191 vs '
      'native_bindings_ffi.dart:297).',
  'example/08_all_errors.dart':
      'TODO: hangs in the MontyResourceError (timeout) section.',
  'example/09_limits_and_code_capture.dart':
      'TODO: hangs after the MontyLimits banner.',
};

void main() {
  final examples =
      Directory('example')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.path)
          .toList()
        ..sort();

  group('example smoke', () {
    for (final ex in examples) {
      test(
        ex,
        () async {
          // Runtime skip — survives `--run-skipped`, which the tag-level
          // skip directive in dart_test.yaml requires to enable this suite.
          final skipReason = _skipReasons[ex];
          if (skipReason != null) {
            markTestSkipped(skipReason);

            return;
          }
          final result = await Process.run('dart', ['run', ex]);
          expect(
            result.exitCode,
            equals(0),
            reason:
                'exit=${result.exitCode}\n'
                '--- stdout ---\n${result.stdout}\n'
                '--- stderr ---\n${result.stderr}',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}

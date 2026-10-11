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
const _skipReasons = <String, String>{
  // 06 was skipped here, blocked on core#152 (Monty.compile() always failed:
  // the one-shot handle cannot snapshot). The precompile API was removed
  // instead of fixed, the example lost its compile section and was renamed
  // example/06_platform_apis.dart, and it is enforced again.
  //
  // 08 and 09 were skipped for "hangs". Measured 2026-09-14: NEITHER HANGS.
  // Both run to completion and exit 0. That was the last of four stale skip
  // reasons in this map -- all four named a cause that was no longer true, and
  // two of them hid live defects (core#152, and the one below).
  //
  // They are unskipped because they meet this harness's bar: compile and exit
  // 0. Be clear about what that bar does NOT cover -- both examples print a
  // section banner and then nothing, because `Monty.exec()` does not throw and
  // their `on MontyResourceError catch` blocks are dead code. Tracked
  // separately; a smoke test that only checks the exit code cannot see it.
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

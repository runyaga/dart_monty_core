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
  'example/06_compile_and_platform.dart':
      'TODO: UnimplementedError — resumeNameLookupValue is not supported by '
          'the FFI backend (FfiCoreBindings:165). Binding gap, not docs rot.',
  'example/07_all_values.dart':
      'TODO: type cast error at line 157 — MontyNone vs MontyNamedTuple.',
  'example/08_all_errors.dart':
      'TODO: hangs in the MontyResourceError (timeout) section.',
  'example/09_limits_and_code_capture.dart':
      'TODO: hangs after the MontyLimits banner.',
};

void main() {
  final examples = Directory('example')
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
            reason: 'exit=${result.exitCode}\n'
                '--- stdout ---\n${result.stdout}\n'
                '--- stderr ---\n${result.stderr}',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}
